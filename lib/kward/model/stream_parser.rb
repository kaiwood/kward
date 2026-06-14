require "json"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Parses streaming provider responses into Kward assistant messages.
  #
  # `ModelStreamParser` is intentionally provider-shape focused and side-effect
  # light: it accumulates assistant text, reasoning summaries, tool calls, and
  # normalized usage from SSE events. Network IO, retries, credentials, and
  # telemetry stay in `Client`; frontend rendering stays in CLI/RPC event
  # handlers. Keep parser methods deterministic and easy to unit test with raw
  # response bodies.
  module ModelStreamParser
    module_function

    def parse_openai_chat_sse(body, on_assistant_delta: nil, usage_normalizer: nil)
      content = +""
      tool_calls = []
      usage = nil
      body.split(/\r?\n\r?\n/).each do |block|
        data = block.lines.filter_map { |line| line.start_with?("data:") ? line.delete_prefix("data:").strip : nil }.join("\n")
        next if data.empty? || data == "[DONE]"

        event = JSON.parse(data)
        usage ||= usage_normalizer&.call(event["usage"])
        choice = Array(event["choices"]).first || {}
        delta = choice["delta"] || {}
        if delta["content"]
          text = delta["content"].to_s
          content << text
          on_assistant_delta&.call(text)
        end
        Array(delta["tool_calls"]).each do |tool_call|
          merge_streaming_tool_call(tool_calls, tool_call)
        end
        message = choice["message"] || {}
        content << message["content"].to_s if content.empty? && message["content"]
        Array(message["tool_calls"]).each { |tool_call| merge_streaming_tool_call(tool_calls, tool_call) }
      end
      result = { "role" => "assistant", "content" => content }
      result["tool_calls"] = finalized_streaming_tool_calls(tool_calls) unless tool_calls.empty?
      result["usage"] = usage if usage
      result
    rescue JSON::ParserError => e
      raise "Copilot returned invalid SSE JSON: #{e.message}"
    end

    def parse_codex_sse(body, on_reasoning_delta: nil, on_assistant_delta: nil, usage_normalizer: nil, request_error_class: nil)
      state = codex_sse_state
      body.split(/\r?\n\r?\n/).each do |block|
        process_codex_sse_block(block, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class)
      end
      codex_sse_message(state)
    rescue JSON::ParserError => e
      raise "Codex OAuth returned invalid SSE JSON: #{e.message}"
    end

    # Incrementally parses a Codex/Responses SSE HTTP response body.
    #
    # Deltas are yielded as soon as complete SSE blocks arrive so interactive
    # frontends can render streamed assistant and reasoning text without waiting
    # for the provider to close the response.
    def parse_codex_sse_stream(response, on_reasoning_delta: nil, on_assistant_delta: nil, cancellation: nil, usage_normalizer: nil, request_error_class: nil)
      state = codex_sse_state
      buffer = +""

      response.read_body do |chunk|
        cancellation&.raise_if_cancelled!
        buffer << chunk
        while (index = buffer.index(/\r?\n\r?\n/))
          delimiter = Regexp.last_match[0]
          block = buffer[0...index]
          buffer = buffer[(index + delimiter.length)..] || +""
          process_codex_sse_block(block, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class)
        end
      end
      cancellation&.raise_if_cancelled!
      process_codex_sse_block(buffer, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class) unless buffer.empty?
      codex_sse_message(state)
    rescue JSON::ParserError => e
      raise "Codex OAuth returned invalid SSE JSON: #{e.message}"
    end

    def parse_anthropic_sse_stream(response, on_reasoning_delta: nil, on_assistant_delta: nil, cancellation: nil, usage_normalizer: nil, request_error_class: nil)
      state = anthropic_sse_state
      buffer = +""
      response.read_body do |chunk|
        cancellation&.raise_if_cancelled!
        buffer << chunk
        while (index = buffer.index(/\r?\n\r?\n/))
          delimiter = Regexp.last_match[0]
          block = buffer[0...index]
          buffer = buffer[(index + delimiter.length)..] || +""
          process_anthropic_sse_block(block, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class)
        end
      end
      cancellation&.raise_if_cancelled!
      process_anthropic_sse_block(buffer, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class) unless buffer.empty?
      anthropic_sse_message(state)
    rescue JSON::ParserError => e
      raise "Anthropic returned invalid SSE JSON: #{e.message}"
    end

    def anthropic_sse_state
      { content: +"", reasoning_summary: +"", blocks: {}, tool_calls: [], usage: nil }
    end

    def process_anthropic_sse_block(block, state, on_reasoning_delta: nil, on_assistant_delta: nil, usage_normalizer: nil, request_error_class: nil)
      event_name = nil
      data = block.lines.filter_map do |line|
        event_name = line.delete_prefix("event:").strip if line.start_with?("event:")
        line.start_with?("data:") ? line.delete_prefix("data:").strip : nil
      end.join("\n")
      return if data.empty? || data == "[DONE]"
      raise anthropic_sse_error(data, request_error_class: request_error_class) if event_name == "error"

      event = JSON.parse(data)
      case event["type"]
      when "message_start"
        state[:usage] ||= usage_normalizer&.call(event.dig("message", "usage"))
      when "content_block_start"
        block_data = event["content_block"] || {}
        state[:blocks][event["index"].to_i] = block_data.merge("partial_json" => "")
        if block_data["type"] == "text"
          text = block_data["text"].to_s
          state[:content] << text
          on_assistant_delta&.call(text) unless text.empty?
        elsif block_data["type"] == "thinking"
          text = block_data["thinking"].to_s
          state[:reasoning_summary] << text
          on_reasoning_delta&.call(text) unless text.empty?
        end
      when "content_block_delta"
        current = state[:blocks][event["index"].to_i] ||= { "partial_json" => "" }
        delta = event["delta"] || {}
        case delta["type"]
        when "text_delta"
          text = delta["text"].to_s
          state[:content] << text
          on_assistant_delta&.call(text)
        when "thinking_delta"
          text = delta["thinking"].to_s
          state[:reasoning_summary] << text
          on_reasoning_delta&.call(text)
        when "input_json_delta"
          current["partial_json"] = current["partial_json"].to_s + delta["partial_json"].to_s
        end
      when "content_block_stop"
        block_data = state[:blocks][event["index"].to_i]
        tool_call = anthropic_tool_call(block_data)
        state[:tool_calls] << tool_call if tool_call
      when "message_delta"
        state[:usage] = usage_normalizer&.call(event["usage"]) || state[:usage]
      end
    end

    def anthropic_sse_error(data, request_error_class: nil)
      if request_error_class
        request_error_class.new(provider: "Anthropic", code: 400, body: data)
      else
        data
      end
    end

    def anthropic_tool_call(block_data)
      return nil unless block_data.is_a?(Hash) && block_data["type"] == "tool_use"

      name = from_claude_code_tool_name(block_data["name"])
      arguments = block_data["partial_json"].to_s
      arguments = JSON.dump(block_data["input"] || {}) if arguments.empty?
      arguments = "{}" if arguments.empty?
      {
        "id" => block_data["id"] || "call_#{name}",
        "type" => "function",
        "function" => { "name" => name, "arguments" => arguments }
      }
    end

    def anthropic_sse_message(state)
      message = { "role" => "assistant", "content" => state[:content] }
      message["reasoning_summary"] = state[:reasoning_summary] unless state[:reasoning_summary].empty?
      message["tool_calls"] = state[:tool_calls] unless state[:tool_calls].empty?
      message["usage"] = state[:usage] if state[:usage]
      message
    end

    def from_claude_code_tool_name(name)
      case name.to_s
      when "Read" then "read_file"
      when "Write" then "write_file"
      when "Edit" then "edit_file"
      when "Bash" then "run_shell_command"
      when "WebSearch" then "web_search"
      when "AskUserQuestion" then "ask_user_question"
      else name.to_s
      end
    end

    def merge_streaming_tool_call(tool_calls, delta)
      index = (delta["index"] || tool_calls.length).to_i
      tool_calls[index] ||= { "id" => nil, "type" => "function", "function" => { "name" => "", "arguments" => "" } }
      current = tool_calls[index]
      current["id"] = delta["id"] if delta["id"]
      current["type"] = delta["type"] if delta["type"]
      function = delta["function"] || {}
      current["function"]["name"] << function["name"].to_s if function["name"]
      current["function"]["arguments"] << function["arguments"].to_s if function["arguments"]
    end

    def finalized_streaming_tool_calls(tool_calls)
      tool_calls.compact.each_with_index.map do |tool_call, index|
        tool_call["id"] ||= "call_#{index}"
        tool_call["type"] ||= "function"
        tool_call["function"] ||= { "name" => "", "arguments" => "{}" }
        tool_call["function"]["arguments"] = "{}" if tool_call["function"]["arguments"].to_s.empty?
        tool_call
      end
    end

    def codex_sse_state
      { content: +"", reasoning_summary: +"", tool_calls: [], final_output: [], usage: nil }
    end

    def process_codex_sse_block(block, state, on_reasoning_delta: nil, on_assistant_delta: nil, usage_normalizer: nil, request_error_class: nil)
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
        state[:usage] ||= usage_normalizer&.call(response["usage"]) if response.is_a?(Hash)
        state[:usage] ||= usage_normalizer&.call(event["usage"])
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
        raise codex_sse_error(event, request_error_class: request_error_class)
      end
    end

    def codex_sse_error(event, request_error_class: nil)
      response = event["response"]
      error = event["error"] || (response["error"] if response.is_a?(Hash)) || {}
      message = if error.is_a?(Hash)
                  [error["code"], error["message"]].compact.join(": ")
                else
                  error.to_s
                end
      message = event["type"].to_s if message.empty?
      code = error.is_a?(Hash) && error["code"].to_s == "server_error" ? 500 : 400
      if request_error_class
        request_error_class.new(provider: "Codex", code: code, body: "#{event["type"]}: #{message}")
      else
        "#{event["type"]}: #{message}"
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
      message["usage"] = state[:usage] if state[:usage]
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
  end
end
