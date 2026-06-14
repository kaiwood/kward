require_relative "../image_attachments"
require_relative "../message_access"
require_relative "model_info"

module Kward
  # Converts Kward conversation/tool data into provider-specific request shapes.
  #
  # This module is mixed into `Client` because it needs provider configuration
  # helpers such as `model_for` and `reasoning_effort`. Keep pure transcript and
  # schema transformations here; keep network transport, credentials, retries,
  # and telemetry in `Client`.
  #
  # Kward stores one internal transcript shape, then projects it into either
  # Chat Completions-style messages or Responses/Codex input items. Preserve both
  # symbol and string key handling through `MessageAccess` so restored sessions,
  # tests, and RPC-normalized messages keep working.
  module ModelPayloads
    private

    def request_payload(provider, messages, tools, max_tokens: nil, model: nil, reasoning: nil)
      parts = build_context_parts(provider, messages, tools, model: model)
      payload = { model: parts[:model], messages: parts[:messages], tools: parts[:tools] }
      payload[:reasoning] = { effort: reasoning_effort("OpenRouter") } if provider == "OpenRouter" && reasoning != false
      payload[:max_tokens] = max_tokens.to_i if max_tokens.to_i.positive?
      payload
    end

    def validate_image_support!(provider, model, messages)
      return if ModelInfo.supports_images?(provider, model)
      return unless messages_include_images?(messages)

      raise "Model '#{model}' does not support image inputs. Switch to a vision-capable model or remove the image attachment."
    end

    def messages_include_images?(messages)
      messages.any? do |message|
        content = MessageAccess.content(message)
        content.is_a?(Array) && content.any? { |part| (part[:type] || part["type"]).to_s == "image" }
      end
    end

    def chat_messages(messages)
      messages.map do |message|
        role = MessageAccess.role(message)
        content = MessageAccess.content(message)
        case role.to_s
        when "compactionSummary"
          { role: "assistant", content: MessageAccess.summary(message) || content.to_s }
        when "assistant"
          api_message(message, role: "assistant", content: content.is_a?(Array) ? plain_content(content) : content, keys: ["tool_calls", :tool_calls, "name", :name])
        when "toolResult"
          api_message(message, role: "tool", content: plain_content(content).to_s, keys: ["tool_call_id", :tool_call_id, "toolCallId", :toolCallId, "name", :name, "toolName", :toolName])
        when "tool"
          api_message(message, role: "tool", content: plain_content(content).to_s, keys: ["tool_call_id", :tool_call_id, "name", :name])
        when "user"
          api_message(message, role: "user", content: content.is_a?(Array) ? chat_user_content(content) : content, keys: ["name", :name])
        else
          api_message(message, role: role, content: content, keys: ["name", :name])
        end
      end
    end

    def api_message(message, role:, content:, keys: [])
      result = { role: role, content: content }
      keys.each_slice(2) do |string_key, symbol_key|
        value = MessageAccess.value(message, string_key) || MessageAccess.value(message, symbol_key)
        next if value.nil?

        target_key = case string_key.to_s
                     when "toolCallId" then :tool_call_id
                     when "toolName" then :name
                     else string_key.to_sym
                     end
        result[target_key] = value
      end
      result
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

    def codex_payload(messages, tools, max_tokens: nil, model: nil, reasoning: nil)
      parts = build_context_parts("Codex", messages, tools, model: model)
      payload = {
        model: parts[:model],
        instructions: parts[:instructions],
        input: parts[:input],
        tools: parts[:tools],
        tool_choice: "auto",
        parallel_tool_calls: false,
        stream: true,
        store: false,
        include: []
      }
      payload[:reasoning] = { effort: reasoning_effort("Codex"), summary: "auto" } unless reasoning == false
      payload
    end

    # Builds provider-neutral context parts before final JSON serialization.
    #
    # Codex and Copilot Responses use `instructions` plus typed `input` items;
    # OpenRouter and Copilot chat use OpenAI-compatible `messages`. Callers should
    # prefer this method when showing context usage or debugging provider payloads
    # so every frontend sees the same conversion rules.
    def build_context_parts(provider, messages, tools, model: nil)
      if provider == "CopilotResponses"
        instructions, input = codex_messages(messages)
        {
          provider: provider,
          model: model_for("Copilot", override_model: model),
          instructions: instructions.empty? ? "You are a helpful assistant." : instructions,
          input: input,
          tools: tools.map { |tool| codex_tool_schema(tool) }
        }
      elsif provider == "Codex"
        instructions, input = codex_messages(messages)
        {
          provider: provider,
          model: model_for(provider, override_model: model),
          instructions: instructions.empty? ? "You are a helpful assistant." : instructions,
          input: input,
          tools: tools.map { |tool| codex_tool_schema(tool) }
        }
      else
        {
          provider: provider,
          model: model_for(provider, override_model: model),
          messages: chat_messages(messages),
          tools: tools
        }
      end
    end

    def codex_messages(messages)
      instructions = []
      input = []

      messages.each do |message|
        role = MessageAccess.role(message)
        content = MessageAccess.content(message) || ""
        case role.to_s
        when "system"
          instructions << plain_content(content).to_s
        when "tool", "toolResult"
          input << {
            type: "function_call_output",
            call_id: MessageAccess.tool_call_id(message) || MessageAccess.tool_name(message) || "tool-call",
            output: plain_content(content).to_s
          }
        when "assistant"
          content = plain_content(content)
          input << codex_message("assistant", content.to_s) unless content.to_s.empty?
          MessageAccess.tool_calls(message).each do |tool_call|
            function = tool_call[:function] || tool_call["function"] || {}
            input << {
              type: "function_call",
              call_id: tool_call[:id] || tool_call["id"] || function[:name] || function["name"] || "tool-call",
              name: function[:name] || function["name"],
              arguments: function[:arguments] || function["arguments"] || "{}"
            }
          end
        when "compactionSummary"
          summary = MessageAccess.summary(message) || content
          input << codex_message("assistant", summary.to_s) unless summary.to_s.empty?
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

  end
end
