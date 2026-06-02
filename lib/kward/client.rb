require "json"
require "net/http"
require "uri"
require_relative "openai_oauth"

module Kward
  class Client
    OPENROUTER_URL = URI("https://openrouter.ai/api/v1/chat/completions")
    CODEX_URL = URI("https://chatgpt.com/backend-api/codex/responses")
    AUTH_ERROR = "No OpenAI OAuth login found. Run `ruby lib/main.rb login`, or set OPENAI_ACCESS_TOKEN/OPENROUTER_API_KEY."

    def initialize(api_key: ENV["OPENROUTER_API_KEY"], model: nil, openai_access_token: ENV["OPENAI_ACCESS_TOKEN"], oauth: OpenAIOAuth.new)
      @openrouter_api_key = presence(api_key)
      @openai_access_token = presence(openai_access_token)
      @oauth = oauth
      @model = model
    end

    def chat(messages, tools: [], on_reasoning_delta: nil)
      url, token, provider, account_id = credentials
      raise AUTH_ERROR if token.nil? || token.empty?

      return codex_chat(url, token, account_id, messages, tools, on_reasoning_delta: on_reasoning_delta) if provider == "Codex"

      request = Net::HTTP::Post.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request.body = JSON.dump(request_payload(provider, messages, tools))

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "#{provider} request failed: #{response.code} #{response.body}"
      end

      JSON.parse(response.body).fetch("choices").first.fetch("message")
    end

    private

    def codex_chat(url, token, account_id, messages, tools, on_reasoning_delta: nil)
      request = Net::HTTP::Post.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["ChatGPT-Account-Id"] = account_id if account_id
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      request["originator"] = "codex_cli_rs"
      request.body = JSON.dump(codex_payload(messages, tools))

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true, read_timeout: nil) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Codex OAuth request failed: #{response.code} #{redact(response.body, token)}"
      end

      parse_codex_sse(response.body, on_reasoning_delta: on_reasoning_delta)
    end

    def parse_codex_sse(body, on_reasoning_delta: nil)
      content = +""
      reasoning_summary = +""
      tool_calls = []
      final_output = []

      body.split(/\r?\n\r?\n/).each do |block|
        data = block.lines.filter_map { |line| line.start_with?("data:") ? line.delete_prefix("data:").strip : nil }.join("\n")
        next if data.empty? || data == "[DONE]"

        event = JSON.parse(data)
        case event["type"]
        when "response.output_text.delta"
          content << event["delta"].to_s
        when "response.reasoning_summary_text.delta"
          delta = event["delta"].to_s
          reasoning_summary << delta
          on_reasoning_delta&.call(delta)
        when "response.output_item.done"
          item = event["item"]
          final_output << item if item.is_a?(Hash)
          tool_call = codex_tool_call(item)
          tool_calls << tool_call if tool_call
        when "response.completed"
          response = event["response"]
          if content.empty? && response.is_a?(Hash) && response["output"].is_a?(Array)
            final_output = response["output"]
            content << text_from_codex_items(final_output)
            reasoning_summary << reasoning_summary_from_codex_items(final_output) if reasoning_summary.empty?
          end
        when "response.failed", "response.incomplete"
          raise "Codex OAuth response #{event["type"]}: #{event["error"] || event["response"] || event}"
        end
      end

      if tool_calls.empty?
        final_output.each do |item|
          tool_call = codex_tool_call(item)
          tool_calls << tool_call if tool_call
        end
      end

      message = { "role" => "assistant", "content" => content }
      message["reasoning_summary"] = reasoning_summary unless reasoning_summary.empty?
      message["tool_calls"] = tool_calls unless tool_calls.empty?
      message
    rescue JSON::ParserError => e
      raise "Codex OAuth returned invalid SSE JSON: #{e.message}"
    end

    def codex_tool_call(item)
      return nil unless item.is_a?(Hash) && ["function_call", "custom_tool_call"].include?(item["type"])

      name = item["name"].to_s
      return nil if name.empty?

      arguments = item["arguments"] || item["input"] || "{}"
      arguments = JSON.dump(arguments) unless arguments.is_a?(String)
      {
        "id" => (item["call_id"] || item["id"] || "call_#{name}"),
        "type" => "function",
        "function" => { "name" => name, "arguments" => arguments }
      }
    end

    def text_from_codex_items(items)
      items.flat_map do |item|
        next [] unless item.is_a?(Hash)

        if ["output_text", "text"].include?(item["type"])
          item["text"].to_s
        elsif item["type"] == "message" && item["content"].is_a?(Array)
          item["content"].filter_map { |part| part["text"] if part.is_a?(Hash) && ["output_text", "text"].include?(part["type"]) }
        else
          []
        end
      end.join
    end

    def reasoning_summary_from_codex_items(items)
      items.flat_map do |item|
        next [] unless item.is_a?(Hash)

        if item["type"] == "reasoning" && item["summary"].is_a?(Array)
          item["summary"].filter_map { |part| part["text"] if part.is_a?(Hash) }
        else
          []
        end
      end.join
    end

    def credentials
      openai_token = @openai_access_token || @oauth.access_token
      if openai_token
        [CODEX_URL, openai_token, "Codex", @oauth.respond_to?(:account_id) ? @oauth.account_id : nil]
      elsif @openrouter_api_key
        [OPENROUTER_URL, @openrouter_api_key, "OpenRouter", nil]
      else
        [CODEX_URL, nil, "Codex", nil]
      end
    end

    def request_payload(provider, messages, tools)
      payload = { model: model_for(provider), messages: messages, tools: tools }
      payload
    end

    def codex_payload(messages, tools)
      instructions, input = codex_messages(messages)
      {
        model: model_for("Codex"),
        instructions: instructions.empty? ? "You are a helpful assistant." : instructions,
        input: input,
        tools: tools.map { |tool| codex_tool_schema(tool) },
        tool_choice: "auto",
        parallel_tool_calls: false,
        stream: true,
        store: false,
        include: [],
        reasoning: { effort: ENV.fetch("OPENAI_REASONING_EFFORT", "medium"), summary: "auto" }
      }
    end

    def codex_messages(messages)
      instructions = []
      input = []

      messages.each do |message|
        role = message[:role] || message["role"]
        content = message[:content] || message["content"] || ""
        case role.to_s
        when "system"
          instructions << content.to_s
        when "tool"
          input << {
            type: "function_call_output",
            call_id: message[:tool_call_id] || message["tool_call_id"] || message[:name] || message["name"] || "tool-call",
            output: content.to_s
          }
        when "assistant"
          input << codex_message("assistant", content.to_s) unless content.to_s.empty?
          (message[:tool_calls] || message["tool_calls"] || []).each do |tool_call|
            function = tool_call[:function] || tool_call["function"] || {}
            input << {
              type: "function_call",
              call_id: tool_call[:id] || tool_call["id"] || function[:name] || function["name"] || "tool-call",
              name: function[:name] || function["name"],
              arguments: function[:arguments] || function["arguments"] || "{}"
            }
          end
        else
          input << codex_message("user", content.to_s)
        end
      end

      [instructions.join("\n\n"), input]
    end

    def codex_message(role, text)
      type = role == "assistant" ? "output_text" : "input_text"
      { type: "message", role: role, content: [{ type: type, text: text }] }
    end

    def codex_tool_schema(tool)
      function = tool[:function] || tool["function"] || {}
      {
        type: "function",
        name: function[:name] || function["name"],
        description: function[:description] || function["description"] || "",
        parameters: function[:parameters] || function["parameters"] || {},
        strict: false
      }
    end

    def model_for(provider)
      return @model if @model

      if provider == "OpenRouter"
        ENV.fetch("OPENROUTER_MODEL", "openai/gpt-5.5")
      else
        ENV.fetch("OPENAI_MODEL", "gpt-5.5")
      end
    end

    def redact(text, token)
      text.to_s.gsub(token.to_s, "[REDACTED]")
    end

    def presence(value)
      text = value.to_s
      text.empty? ? nil : text
    end
  end
end
