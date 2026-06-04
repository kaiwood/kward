require "json"
require "net/http"
require "uri"
require_relative "image_attachments"
require_relative "openai_oauth"

module Kward
  class Client
    OPENROUTER_URL = URI("https://openrouter.ai/api/v1/chat/completions")
    CODEX_URL = URI("https://chatgpt.com/backend-api/codex/responses")
    AUTH_ERROR = "No OpenAI OAuth login found. Run `ruby lib/main.rb login`, or set OPENAI_ACCESS_TOKEN/OPENROUTER_API_KEY."
    DEFAULT_OPENAI_MODEL = "gpt-5.5"
    DEFAULT_OPENROUTER_MODEL = "openai/gpt-5.5"
    DEFAULT_REASONING_EFFORT = "medium"

    def initialize(api_key: ENV["OPENROUTER_API_KEY"], model: nil, openai_access_token: ENV["OPENAI_ACCESS_TOKEN"], oauth: OpenAIOAuth.new, config_path: OpenAIOAuth.default_config_path)
      @openrouter_api_key = presence(api_key)
      @openai_access_token = presence(openai_access_token)
      @oauth = oauth
      @model = model
      @config_path = File.expand_path(config_path)
      @config = load_config
    end

    def chat(messages, tools: [], on_reasoning_delta: nil, on_assistant_delta: nil)
      url, token, provider, account_id = credentials
      raise AUTH_ERROR if token.nil? || token.empty?

      return codex_chat(url, token, account_id, messages, tools, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta) if provider == "Codex"

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

      message = JSON.parse(response.body).fetch("choices").first.fetch("message")
      on_assistant_delta&.call(message.fetch("content", ""))
      message
    end

    def current_provider
      _url, _token, provider = credentials
      provider
    rescue StandardError
      openai_configured? ? "Codex" : "OpenRouter"
    end

    def current_model
      model_for(current_provider)
    end

    def current_reasoning_effort
      reasoning_effort
    end

    def available_models
      provider = current_provider
      openai_model = model_for("Codex")
      openrouter_model = model_for("OpenRouter")
      models = [
        { provider: "Codex", id: DEFAULT_OPENAI_MODEL, current: provider == "Codex" && openai_model == DEFAULT_OPENAI_MODEL },
        { provider: "OpenRouter", id: DEFAULT_OPENROUTER_MODEL, current: provider == "OpenRouter" && openrouter_model == DEFAULT_OPENROUTER_MODEL }
      ]
      models << { provider: "Codex", id: openai_model, current: provider == "Codex" } unless openai_model == DEFAULT_OPENAI_MODEL
      models << { provider: "OpenRouter", id: openrouter_model, current: provider == "OpenRouter" } unless openrouter_model == DEFAULT_OPENROUTER_MODEL
      models
    end

    def reload_config
      @config = load_config
    end

    private

    def codex_chat(url, token, account_id, messages, tools, on_reasoning_delta: nil, on_assistant_delta: nil)
      request = Net::HTTP::Post.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["ChatGPT-Account-Id"] = account_id if account_id
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      request["originator"] = "codex_cli_rs"
      request.body = JSON.dump(codex_payload(messages, tools))

      message = nil
      Net::HTTP.start(url.hostname, url.port, use_ssl: true, read_timeout: nil) do |http|
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            body = +""
            response.read_body { |chunk| body << chunk }
            raise "Codex OAuth request failed: #{response.code} #{redact(body, token)}"
          end

          message = parse_codex_sse_stream(response, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta)
        end
      end

      message
    end

    def parse_codex_sse(body, on_reasoning_delta: nil, on_assistant_delta: nil)
      state = codex_sse_state
      body.split(/\r?\n\r?\n/).each do |block|
        process_codex_sse_block(block, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta)
      end
      codex_sse_message(state)
    rescue JSON::ParserError => e
      raise "Codex OAuth returned invalid SSE JSON: #{e.message}"
    end

    def parse_codex_sse_stream(response, on_reasoning_delta: nil, on_assistant_delta: nil)
      state = codex_sse_state
      buffer = +""

      response.read_body do |chunk|
        buffer << chunk
        while (index = buffer.index(/\r?\n\r?\n/))
          delimiter = Regexp.last_match[0]
          block = buffer[0...index]
          buffer = buffer[(index + delimiter.length)..] || +""
          process_codex_sse_block(block, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta)
        end
      end
      process_codex_sse_block(buffer, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta) unless buffer.empty?
      codex_sse_message(state)
    rescue JSON::ParserError => e
      raise "Codex OAuth returned invalid SSE JSON: #{e.message}"
    end

    def codex_sse_state
      { content: +"", reasoning_summary: +"", tool_calls: [], final_output: [] }
    end

    def process_codex_sse_block(block, state, on_reasoning_delta: nil, on_assistant_delta: nil)
      data = block.lines.filter_map { |line| line.start_with?("data:") ? line.delete_prefix("data:").strip : nil }.join("\n")
      return if data.empty? || data == "[DONE]"

      event = JSON.parse(data)
      case event["type"]
      when "response.output_text.delta"
        delta = event["delta"].to_s
        state[:content] << delta
        on_assistant_delta&.call(delta)
      when "response.reasoning_summary_text.delta"
        delta = event["delta"].to_s
        state[:reasoning_summary] << delta
        on_reasoning_delta&.call(delta)
      when "response.output_item.done"
        item = event["item"]
        state[:final_output] << item if item.is_a?(Hash)
        tool_call = codex_tool_call(item)
        state[:tool_calls] << tool_call if tool_call
      when "response.completed"
        response = event["response"]
        if state[:content].empty? && response.is_a?(Hash) && response["output"].is_a?(Array)
          state[:final_output] = response["output"]
          text = text_from_codex_items(state[:final_output])
          state[:content] << text
          on_assistant_delta&.call(text) unless text.empty?
          if state[:reasoning_summary].empty?
            state[:reasoning_summary] << reasoning_summary_from_codex_items(state[:final_output])
          end
        end
      when "response.failed", "response.incomplete"
        raise "Codex OAuth response #{event["type"]}: #{event["error"] || event["response"] || event}"
      end
    end

    def codex_sse_message(state)
      if state[:tool_calls].empty?
        state[:final_output].each do |item|
          tool_call = codex_tool_call(item)
          state[:tool_calls] << tool_call if tool_call
        end
      end

      message = { "role" => "assistant", "content" => state[:content] }
      message["reasoning_summary"] = state[:reasoning_summary] unless state[:reasoning_summary].empty?
      message["tool_calls"] = state[:tool_calls] unless state[:tool_calls].empty?
      message
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
      payload = { model: model_for(provider), messages: chat_messages(messages), tools: tools }
      payload
    end

    def chat_messages(messages)
      messages.map do |message|
        role = message[:role] || message["role"]
        content = message[:content] || message["content"]
        content_key = message.key?(:content) ? :content : "content"
        if role.to_s == "assistant" && content.is_a?(Array)
          next message.merge(content_key => plain_content(content))
        end
        next message unless role.to_s == "user" && content.is_a?(Array)

        message.merge(content_key => chat_user_content(content))
      end
    end

    def chat_user_content(content)
      content.filter_map do |part|
        type = part[:type] || part["type"]
        if type == "text"
          { type: "text", text: part[:text] || part["text"] || "" }
        elsif type == "image"
          { type: "image_url", image_url: { url: ImageAttachments.data_url(part) } }
        end
      end
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
        reasoning: { effort: reasoning_effort, summary: "auto" }
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
          instructions << plain_content(content).to_s
        when "tool"
          input << {
            type: "function_call_output",
            call_id: message[:tool_call_id] || message["tool_call_id"] || message[:name] || message["name"] || "tool-call",
            output: plain_content(content).to_s
          }
        when "assistant"
          content = plain_content(content)
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
          input << codex_user_message(content)
        end
      end

      [instructions.join("\n\n"), input]
    end

    def codex_user_message(content)
      return codex_message("user", content.to_s) unless content.is_a?(Array)

      parts = content.filter_map do |part|
        type = part[:type] || part["type"]
        if type == "text"
          { type: "input_text", text: part[:text] || part["text"] || "" }
        elsif type == "image"
          { type: "input_image", image_url: ImageAttachments.data_url(part) }
        end
      end
      { type: "message", role: "user", content: parts }
    end

    def codex_message(role, text)
      type = role == "assistant" ? "output_text" : "input_text"
      { type: "message", role: role, content: [{ type: type, text: text }] }
    end

    def plain_content(content)
      return content unless content.is_a?(Array)

      content.filter_map do |part|
        type = part[:type] || part["type"]
        part[:text] || part["text"] if type == "text"
      end.join
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
        ENV["OPENROUTER_MODEL"] || config_value("openrouter_model", "model") || DEFAULT_OPENROUTER_MODEL
      else
        ENV["OPENAI_MODEL"] || config_value("openai_model", "model") || DEFAULT_OPENAI_MODEL
      end
    end

    def reasoning_effort
      ENV["OPENAI_REASONING_EFFORT"] || config_value("openai_reasoning_effort", "reasoning_effort", "thinking_level") || DEFAULT_REASONING_EFFORT
    end

    def openai_configured?
      !@openai_access_token.to_s.empty? || @oauth.access_token.to_s != ""
    rescue StandardError
      false
    end

    def config_value(*keys)
      keys.each do |key|
        value = @config[key]
        text = presence(value)
        return text if text
      end
      nil
    end

    def load_config
      return {} unless File.exist?(@config_path)

      JSON.parse(File.read(@config_path))
    rescue JSON::ParserError
      raise "Invalid Kward config JSON: #{@config_path}"
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
