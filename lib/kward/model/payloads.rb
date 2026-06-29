require "json"
require_relative "../image_attachments"
require_relative "../message_access"
require_relative "../tools/tool_call"
require_relative "model_info"

# Namespace for the Kward CLI agent runtime.
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
      raise "OpenRouter model is not configured. Run `kward openrouter refresh` and select a cached model." if provider == "OpenRouter" && parts[:model].to_s.empty?

      payload = { model: parts[:model], messages: parts[:messages], tools: parts[:tools] }
      payload[:reasoning] = { effort: reasoning || reasoning_effort("OpenRouter") } if provider == "OpenRouter" && reasoning != false
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

    def anthropic_payload(messages, tools, max_tokens: nil, model: nil, reasoning: nil)
      parts = build_context_parts("Anthropic", messages, tools, model: model)
      system = [{ type: "text", text: "You are Claude Code, Anthropic's official CLI for Claude." }]
      system << { type: "text", text: parts[:system] } unless parts[:system].to_s.empty?
      payload = {
        model: parts[:model],
        system: system,
        messages: parts[:messages],
        max_tokens: max_tokens.to_i.positive? ? max_tokens.to_i : 16_384,
        stream: true
      }
      payload[:tools] = parts[:tools] unless parts[:tools].empty?
      if reasoning != false
        payload[:thinking] = { type: "adaptive", display: "summarized" }
        payload[:output_config] = { effort: reasoning || reasoning_effort("Anthropic") }
      else
        payload[:thinking] = { type: "disabled" }
      end
      payload
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
      payload[:reasoning] = { effort: reasoning || reasoning_effort("Codex"), summary: "auto" } unless reasoning == false
      payload
    end

    # Builds provider-neutral context parts before final JSON serialization.
    #
    # Codex and Copilot Responses use `instructions` plus typed `input` items;
    # OpenRouter and Copilot chat use OpenAI-compatible `messages`. Callers should
    # prefer this method when showing context usage or debugging provider payloads
    # so every frontend sees the same conversion rules.
    def build_context_parts(provider, messages, tools, model: nil)
      if provider == "Anthropic"
        system, anthropic_messages = anthropic_messages(messages)
        {
          provider: provider,
          model: model_for(provider, override_model: model),
          system: system,
          messages: anthropic_messages,
          tools: tools.map { |tool| anthropic_tool_schema(tool) }
        }
      elsif provider == "CopilotResponses"
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

    def anthropic_messages(messages)
      system = []
      output = []
      messages.each do |message|
        role = MessageAccess.role(message)
        content = MessageAccess.content(message) || ""
        case role.to_s
        when "system"
          system << plain_content(content).to_s
        when "assistant"
          blocks = []
          text = plain_content(content).to_s
          blocks << { type: "text", text: text } unless text.empty?
          MessageAccess.tool_calls(message).each do |tool_call|
            function = tool_call[:function] || tool_call["function"] || {}
            name = function[:name] || function["name"]
            arguments = function[:arguments] || function["arguments"] || "{}"
            blocks << {
              type: "tool_use",
              id: normalize_anthropic_tool_call_id(tool_call[:id] || tool_call["id"] || "call_#{name}"),
              name: claude_code_tool_name(name),
              input: parse_tool_arguments(arguments)
            }
          end
          output << { role: "assistant", content: blocks } unless blocks.empty?
        when "tool", "toolResult"
          output << {
            role: "user",
            content: [{
              type: "tool_result",
              tool_use_id: normalize_anthropic_tool_call_id(MessageAccess.tool_call_id(message) || MessageAccess.tool_name(message) || "tool-call"),
              content: plain_content(content).to_s
            }]
          }
        when "compactionSummary"
          summary = MessageAccess.summary(message) || content
          output << { role: "assistant", content: [{ type: "text", text: summary.to_s }] } unless summary.to_s.empty?
        else
          output << { role: "user", content: anthropic_user_content(content) }
        end
      end
      [system.join("\n\n"), output]
    end

    def anthropic_user_content(content)
      return content.to_s unless content.is_a?(Array)

      content.filter_map do |part|
        type = part[:type] || part["type"]
        if type == "text"
          { type: "text", text: part[:text] || part["text"] || "" }
        elsif type == "image"
          mime_type, data = ImageAttachments.data_url(part).split(",", 2)
          media_type = mime_type.to_s[/data:([^;]+)/, 1] || "image/png"
          { type: "image", source: { type: "base64", media_type: media_type, data: data.to_s } }
        end
      end
    end

    CLAUDE_CODE_TOOL_NAMES = %w[Read Write Edit Bash Grep Glob AskUserQuestion EnterPlanMode ExitPlanMode KillShell NotebookEdit Skill Task TaskOutput TodoWrite WebFetch WebSearch].freeze

    def claude_code_tool_name(name)
      mapped = {
        "read_file" => "Read",
        "write_file" => "Write",
        "edit_file" => "Edit",
        "run_shell_command" => "Bash",
        "web_search" => "WebSearch",
        "fetch_content" => "WebFetch",
        "ask_user_question" => "AskUserQuestion"
      }[name.to_s]
      return mapped if mapped

      lookup = CLAUDE_CODE_TOOL_NAMES.find { |tool_name| tool_name.downcase == name.to_s.downcase }
      lookup || name.to_s
    end

    def normalize_anthropic_tool_call_id(id)
      id.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")[0, 64]
    end

    def parse_tool_arguments(arguments)
      ToolCall.parse_arguments(arguments)
    end

    def anthropic_tool_schema(tool)
      function = tool[:function] || tool["function"] || {}
      schema = function[:parameters] || function["parameters"] || {}
      {
        name: claude_code_tool_name(function[:name] || function["name"]),
        description: function[:description] || function["description"] || "",
        input_schema: {
          type: "object",
          properties: schema[:properties] || schema["properties"] || {},
          required: schema[:required] || schema["required"] || []
        },
        eager_input_streaming: true
      }
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
          response_items = codex_replay_response_items(message)
          if response_items.empty?
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
          else
            input.concat(response_items)
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

    def codex_replay_response_items(message)
      items = MessageAccess.response_items(message)
      return [] if items.empty?

      items.filter_map { |item| codex_replay_response_item(item) }
    end

    def codex_replay_response_item(item)
      return nil unless item.is_a?(Hash)

      case item[:type] || item["type"]
      when "reasoning"
        codex_replay_reasoning_item(item)
      when "message"
        codex_replay_message_item(item)
      when "function_call", "custom_tool_call"
        codex_replay_tool_call_item(item)
      end
    end

    def codex_replay_reasoning_item(item)
      result = { type: "reasoning" }
      summary = item[:summary] || item["summary"]
      content = item[:content] || item["content"]
      encrypted_content = item[:encrypted_content] || item["encrypted_content"]
      result[:summary] = summary if summary.is_a?(Array)
      result[:content] = content if content.is_a?(Array)
      result[:encrypted_content] = encrypted_content if encrypted_content
      result
    end

    def codex_replay_message_item(item)
      content = item[:content] || item["content"]
      return nil unless content.is_a?(Array)

      result = { type: "message", role: item[:role] || item["role"] || "assistant", content: codex_replay_message_content(content) }
      phase = item[:phase] || item["phase"]
      result[:phase] = phase if phase
      result
    end

    def codex_replay_message_content(content)
      content.filter_map do |part|
        next unless part.is_a?(Hash)

        type = part[:type] || part["type"]
        next unless ["output_text", "text", "refusal"].include?(type)

        replay_part = { type: type }
        text = part[:text] || part["text"]
        refusal = part[:refusal] || part["refusal"]
        replay_part[:text] = text.to_s if text || type != "refusal"
        replay_part[:refusal] = refusal.to_s if refusal
        annotations = part[:annotations] || part["annotations"]
        replay_part[:annotations] = annotations if annotations.is_a?(Array)
        replay_part
      end
    end

    def codex_replay_tool_call_item(item)
      type = item[:type] || item["type"]
      result = { type: type }
      call_id = item[:call_id] || item["call_id"]
      name = item[:name] || item["name"]
      arguments = item[:arguments] || item["arguments"]
      input = item[:input] || item["input"]
      result[:call_id] = call_id if call_id
      result[:name] = name if name
      result[:arguments] = arguments if arguments
      result[:input] = input if input
      result
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
