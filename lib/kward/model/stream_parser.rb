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

    def parse_openai_chat_sse(body, on_assistant_delta: nil, usage_normalizer: nil, provider_label: "OpenAI-compatible provider")
      state = openai_chat_sse_state
      body.split(/\r?\n\r?\n/).each do |block|
        process_openai_chat_sse_block(block, state, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer)
      end
      openai_chat_sse_message(state)
    rescue JSON::ParserError => e
      raise "#{provider_label} returned invalid SSE JSON: #{e.message}"
    end

    # Incrementally parses a Chat Completions SSE HTTP response body. Local
    # OpenAI-compatible servers stream this shape, so emit assistant deltas as
    # complete SSE blocks arrive rather than waiting for connection close.
    def parse_openai_chat_sse_stream(response, on_assistant_delta: nil, cancellation: nil, usage_normalizer: nil, provider_label: "OpenAI-compatible provider")
      state = openai_chat_sse_state
      buffer = +""

      response.read_body do |chunk|
        cancellation&.raise_if_cancelled!
        buffer << chunk
        while (index = buffer.index(/\r?\n\r?\n/))
          delimiter = Regexp.last_match[0]
          block = buffer[0...index]
          buffer = buffer[(index + delimiter.length)..] || +""
          process_openai_chat_sse_block(block, state, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer)
        end
      end
      cancellation&.raise_if_cancelled!
      process_openai_chat_sse_block(buffer, state, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer) unless buffer.empty?
      openai_chat_sse_message(state)
    rescue JSON::ParserError => e
      raise "#{provider_label} returned invalid SSE JSON: #{e.message}"
    end

    def openai_chat_sse_state
      { content: +"", tool_calls: [], usage: nil }
    end

    def process_openai_chat_sse_block(block, state, on_assistant_delta: nil, usage_normalizer: nil)
      data = block.lines.filter_map { |line| line.start_with?("data:") ? line.delete_prefix("data:").strip : nil }.join("\n")
      return if data.empty? || data == "[DONE]"

      event = JSON.parse(data)
      state[:usage] ||= usage_normalizer&.call(event["usage"])
      choice = Array(event["choices"]).first || {}
      delta = choice["delta"] || {}
      if delta["content"]
        text = delta["content"].to_s
        state[:content] << text
        on_assistant_delta&.call(text)
      end
      Array(delta["tool_calls"]).each { |tool_call| merge_streaming_tool_call(state[:tool_calls], tool_call) }
      message = choice["message"] || {}
      state[:content] << message["content"].to_s if state[:content].empty? && message["content"]
      Array(message["tool_calls"]).each { |tool_call| merge_streaming_tool_call(state[:tool_calls], tool_call) }
    end

    def openai_chat_sse_message(state)
      result = { "role" => "assistant", "content" => state[:content] }
      result["tool_calls"] = finalized_streaming_tool_calls(state[:tool_calls]) unless state[:tool_calls].empty?
      result["usage"] = state[:usage] if state[:usage]
      result
    end

    def parse_codex_sse(body, provider_label: "Codex", on_reasoning_delta: nil, on_reasoning_boundary: nil, on_assistant_delta: nil, show_raw_reasoning: false, usage_normalizer: nil, request_error_class: nil)
      state = codex_sse_state(show_raw_reasoning: show_raw_reasoning)
      body.split(/\r?\n\r?\n/).each do |block|
        process_codex_sse_block(block, state, provider_label: provider_label, on_reasoning_delta: on_reasoning_delta, on_reasoning_boundary: on_reasoning_boundary, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class)
      end
      flush_codex_reasoning_delta(state, on_reasoning_delta: on_reasoning_delta)
      codex_sse_message(state)
    rescue JSON::ParserError => e
      raise "#{provider_label} returned invalid SSE JSON: #{e.message}"
    end

    # Incrementally parses a Codex/Responses SSE HTTP response body.
    #
    # Deltas are yielded as soon as complete SSE blocks arrive so interactive
    # frontends can render streamed assistant and reasoning text without waiting
    # for the provider to close the response.
    def parse_codex_sse_stream(response, provider_label: "Codex", on_reasoning_delta: nil, on_reasoning_boundary: nil, on_assistant_delta: nil, cancellation: nil, show_raw_reasoning: false, usage_normalizer: nil, request_error_class: nil)
      state = codex_sse_state(show_raw_reasoning: show_raw_reasoning)
      buffer = +""

      response.read_body do |chunk|
        cancellation&.raise_if_cancelled!
        buffer << chunk
        while (index = buffer.index(/\r?\n\r?\n/))
          delimiter = Regexp.last_match[0]
          block = buffer[0...index]
          buffer = buffer[(index + delimiter.length)..] || +""
          process_codex_sse_block(block, state, provider_label: provider_label, on_reasoning_delta: on_reasoning_delta, on_reasoning_boundary: on_reasoning_boundary, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class)
        end
      end
      cancellation&.raise_if_cancelled!
      process_codex_sse_block(buffer, state, provider_label: provider_label, on_reasoning_delta: on_reasoning_delta, on_reasoning_boundary: on_reasoning_boundary, on_assistant_delta: on_assistant_delta, usage_normalizer: usage_normalizer, request_error_class: request_error_class) unless buffer.empty?
      flush_codex_reasoning_delta(state, on_reasoning_delta: on_reasoning_delta)
      codex_sse_message(state)
    rescue JSON::ParserError => e
      raise "#{provider_label} returned invalid SSE JSON: #{e.message}"
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

    def parse_gemini_sse_stream(response, on_assistant_delta: nil, cancellation: nil, usage_normalizer: nil)
      state = { content: +"", calls: {}, usage: nil }
      buffer = +""
      response.read_body do |chunk|
        cancellation&.raise_if_cancelled!
        buffer << chunk
        while (index = buffer.index(/\r?\n\r?\n/))
          delimiter = Regexp.last_match[0]
          block = buffer[0...index]
          buffer = buffer[(index + delimiter.length)..] || +""
          process_gemini_sse_block(block, state, on_assistant_delta: on_assistant_delta, cancellation: cancellation, usage_normalizer: usage_normalizer)
        end
      end
      cancellation&.raise_if_cancelled!
      process_gemini_sse_block(buffer, state, on_assistant_delta: on_assistant_delta, cancellation: cancellation, usage_normalizer: usage_normalizer) unless buffer.empty?
      gemini_sse_message(state)
    rescue JSON::ParserError => e
      raise "Google Gemini returned invalid SSE JSON: #{e.message}"
    end

    def process_gemini_sse_block(block, state, on_assistant_delta:, cancellation:, usage_normalizer:)
      data = block.lines.filter_map { |line| line.start_with?("data:") ? line.delete_prefix("data:").strip : nil }.join("\n")
      return if data.empty? || data == "[DONE]"

      cancellation&.raise_if_cancelled!
      event = JSON.parse(data)
      Array(event["candidates"]).each_with_index do |candidate, candidate_index|
        Array(candidate.dig("content", "parts")).each_with_index do |part, part_index|
          text = part["text"].to_s
          unless text.empty?
            state[:content] << text
            on_assistant_delta&.call(text)
          end
          merge_gemini_function_call(state[:calls], part["functionCall"], candidate_index: candidate_index, part_index: part_index)
        end
      end
      state[:usage] = usage_normalizer&.call(event["usageMetadata"]) || state[:usage]
    end

    def merge_gemini_function_call(calls, function_call, candidate_index:, part_index:)
      return unless function_call.is_a?(Hash)

      key = function_call["id"] || "#{candidate_index}:#{part_index}:#{function_call["name"]}"
      call = calls[key] ||= { "id" => function_call["id"] || "call_gemini_#{candidate_index}_#{part_index}", "name" => function_call["name"].to_s, "args" => {}, "args_buffer" => +"" }
      call["name"] = function_call["name"].to_s unless function_call["name"].to_s.empty?
      args = function_call["args"]
      if args.is_a?(Hash)
        call["args"].merge!(args)
      elsif !args.nil?
        call["args_buffer"] << args.to_s
      end
    end

    def gemini_sse_message(state)
      message = { "role" => "assistant", "content" => state[:content] }
      unless state[:calls].empty?
        message["tool_calls"] = state[:calls].values.map do |call|
          arguments = call["args_buffer"].empty? ? JSON.dump(call["args"]) : call["args_buffer"]
          { "id" => call["id"], "type" => "function", "function" => { "name" => call["name"], "arguments" => arguments } }
        end
      end
      message["usage"] = state[:usage] if state[:usage]
      message
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
      when "WebFetch" then "fetch_content"
      when "AskUserQuestion" then "ask_user_question"
      else name.to_s
      end
    end

    def merge_streaming_tool_call(tool_calls, delta)
      index = (delta["index"] || tool_calls.length).to_i
      tool_calls[index] ||= { "id" => nil, "type" => "function", "function" => { "name" => +"", "arguments" => +"" } }
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

    def codex_sse_state(show_raw_reasoning: false)
      {
        content: +"",
        raw_content: +"",
        emitted_message_keys: [],
        reasoning_summary: +"",
        raw_reasoning_visible: +"",
        pending_reasoning_delta: +"",
        show_raw_reasoning: show_raw_reasoning,
        tool_calls: [],
        response_item_keys: [],
        items_by_id: {},
        active_item_id: nil,
        current_text_content_part: nil,
        current_reasoning_content_part: nil,
        usage: nil
      }
    end

    def process_codex_sse_block(block, state, provider_label: "Codex", on_reasoning_delta: nil, on_reasoning_boundary: nil, on_assistant_delta: nil, usage_normalizer: nil, request_error_class: nil)
      data = block.lines.filter_map { |line| line.start_with?("data:") ? line.delete_prefix("data:").strip : nil }.join("\n")
      return if data.empty? || data == "[DONE]"

      event = JSON.parse(data)
      case event["type"]
      when "response.output_item.added"
        codex_output_item_added(state, event["item"])
      when "response.content_part.added"
        codex_content_part_added(state, event["part"])
      when "response.output_text.delta", "response.refusal.delta"
        codex_output_text_delta(state, event["delta"], on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta)
      when "response.reasoning_summary_part.added"
        codex_reasoning_summary_part_added(state, event["part"])
      when "response.reasoning_summary_text.delta"
        codex_reasoning_delta(state, event["delta"], on_reasoning_delta: on_reasoning_delta)
      when "response.reasoning_summary_part.done"
        codex_reasoning_part_done(state, on_reasoning_delta: on_reasoning_delta, on_reasoning_boundary: on_reasoning_boundary)
      when "response.reasoning_text.delta"
        codex_raw_reasoning_delta(state, event["delta"], on_reasoning_delta: on_reasoning_delta)
      when "response.reasoning_text.done"
        codex_raw_reasoning_done(state, event["text"], on_reasoning_delta: on_reasoning_delta)
      when "response.function_call_arguments.delta", "response.custom_tool_call_input.delta"
        codex_tool_arguments_delta(state, event["delta"])
      when "response.function_call_arguments.done"
        codex_tool_arguments_done(state, event["arguments"])
      when "response.output_item.done"
        codex_output_item_done(state, event["item"], on_assistant_delta: on_assistant_delta, on_reasoning_delta: on_reasoning_delta)
      when "response.completed"
        response = event["response"]
        state[:usage] ||= usage_normalizer&.call(response["usage"]) if response.is_a?(Hash)
        state[:usage] ||= usage_normalizer&.call(event["usage"])
        if response.is_a?(Hash) && response["output"].is_a?(Array) && state[:response_item_keys].empty?
          response["output"].each do |item|
            codex_output_item_done(state, item, on_assistant_delta: on_assistant_delta, on_reasoning_delta: on_reasoning_delta)
          end
        end
      when "response.failed", "response.incomplete"
        raise codex_sse_error(event, provider_label: provider_label, request_error_class: request_error_class)
      end
    end

    def codex_sse_error(event, provider_label: "Codex", request_error_class: nil)
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
        request_error_class.new(provider: provider_label, code: code, body: "#{event["type"]}: #{message}")
      else
        "#{event["type"]}: #{message}"
      end
    end

    def codex_output_item_added(state, item)
      return unless item.is_a?(Hash)

      item = deep_dup_hash(item)
      item["content"] = [] if item["type"] == "message" && !item["content"].is_a?(Array)
      item["summary"] = [] if item["type"] == "reasoning" && !item["summary"].is_a?(Array)
      remember_codex_item(state, item)
      state[:active_item_id] = codex_item_key(item)
      state[:current_text_content_part] = nil
      state[:current_reasoning_content_part] = nil
    end

    def codex_content_part_added(state, part)
      item = active_codex_item(state)
      return unless item&.fetch("type", nil) == "message" && part.is_a?(Hash)
      return unless ["output_text", "text", "refusal"].include?(part["type"])

      item["content"] ||= []
      item["content"] << deep_dup_hash(part)
      state[:current_text_content_part] = item["content"].last
    end

    def codex_output_text_delta(state, delta, on_reasoning_delta: nil, on_assistant_delta: nil)
      text = delta.to_s
      return if text.empty?

      item = active_codex_item(state)
      if item&.fetch("type", nil) == "message"
        item["content"] ||= [{ "type" => "output_text", "text" => +"" }]
        part = state[:current_text_content_part] || item["content"].last
        part = item["content"].last unless part.is_a?(Hash)
        part["type"] ||= "output_text"
        text_key = part["type"] == "refusal" ? "refusal" : "text"
        part[text_key] = part[text_key].to_s + text
        if codex_streamable_message_item?(item)
          on_assistant_delta&.call(text)
          state[:emitted_message_keys] << codex_item_key(item)
        elsif codex_commentary_message_item?(item)
          on_reasoning_delta&.call(text)
          state[:emitted_message_keys] << codex_item_key(item)
        end
      end
      state[:raw_content] << text
    end

    def codex_reasoning_summary_part_added(state, part)
      item = active_codex_item(state)
      return unless item&.fetch("type", nil) == "reasoning" && part.is_a?(Hash)

      item["summary"] ||= []
      item["summary"] << deep_dup_hash(part)
      state[:current_reasoning_content_part] = nil
    end

    def codex_reasoning_delta(state, delta, on_reasoning_delta: nil)
      text = visible_codex_reasoning_delta(state, delta)
      return if text.empty?

      append_codex_reasoning_text(state, text, on_reasoning_delta: on_reasoning_delta)
    end

    def codex_raw_reasoning_delta(state, delta, on_reasoning_delta: nil)
      text = delta.to_s
      return if text.empty?

      item = active_codex_item(state)
      if item&.fetch("type", nil) == "reasoning" && state[:show_raw_reasoning]
        item["content"] ||= [{ "type" => "reasoning_text", "text" => +"" }]
        part = state[:current_reasoning_content_part] || item["content"].last
        part = item["content"].last unless part.is_a?(Hash)
        part["type"] ||= "reasoning_text"
        part["text"] = part["text"].to_s + text
        state[:current_reasoning_content_part] = part
      end
      return unless state[:show_raw_reasoning]

      visible = visible_codex_reasoning_delta(state, text)
      append_codex_raw_reasoning_text(state, visible, on_reasoning_delta: on_reasoning_delta) unless visible.empty?
    end

    def codex_raw_reasoning_done(state, text, on_reasoning_delta: nil)
      item = active_codex_item(state)
      full_text = text.to_s
      if item&.fetch("type", nil) == "reasoning" && state[:show_raw_reasoning]
        item["content"] ||= [{ "type" => "reasoning_text", "text" => +"" }]
        part = state[:current_reasoning_content_part] || item["content"].last
        part = item["content"].last unless part.is_a?(Hash)
        part["type"] ||= "reasoning_text"
        part["text"] = full_text
        state[:current_reasoning_content_part] = part
      end
      return unless state[:show_raw_reasoning]

      flush_codex_reasoning_delta(state, on_reasoning_delta: on_reasoning_delta)
      visible = sanitize_codex_reasoning_text(full_text)
      emitted = state[:raw_reasoning_visible]
      text = visible.start_with?(emitted) ? visible[emitted.length..].to_s : (emitted.empty? ? visible : +"")
      append_codex_raw_reasoning_text(state, text, on_reasoning_delta: on_reasoning_delta) unless text.empty?
    end

    def codex_reasoning_part_done(state, on_reasoning_delta: nil, on_reasoning_boundary: nil)
      item = active_codex_item(state)
      return unless item&.fetch("type", nil) == "reasoning"
      return if item["summary"].to_a.empty?

      flush_codex_reasoning_delta(state, on_reasoning_delta: on_reasoning_delta)
      item["summary"].last["text"] = "#{item["summary"].last["text"].to_s.rstrip}\n\n"
      state[:reasoning_summary].rstrip!
      state[:reasoning_summary] << "\n\n"
      on_reasoning_boundary&.call
    end

    def append_codex_reasoning_text(state, text, on_reasoning_delta: nil)
      text = compact_codex_reasoning_delta_spacing(state[:reasoning_summary], text)
      return if text.empty?

      item = active_codex_item(state)
      if item&.fetch("type", nil) == "reasoning"
        item["summary"] ||= []
        item["summary"] << { "type" => "summary_text", "text" => +"" } if item["summary"].empty?
        item["summary"].last["text"] = item["summary"].last["text"].to_s + text
      end
      state[:reasoning_summary] << text
      on_reasoning_delta&.call(text)
    end

    def append_codex_raw_reasoning_text(state, text, on_reasoning_delta: nil)
      text = compact_codex_reasoning_delta_spacing(state[:reasoning_summary], text)
      return if text.empty?

      state[:raw_reasoning_visible] << text
      state[:reasoning_summary] << text
      on_reasoning_delta&.call(text)
    end

    def visible_codex_reasoning_delta(state, delta)
      state[:pending_reasoning_delta] << delta.to_s
      sanitized = sanitize_codex_reasoning_text(state[:pending_reasoning_delta], keep_incomplete_comment: true)
      text, pending_prefix = split_trailing_comment_prefix(sanitized[:text])
      state[:pending_reasoning_delta].replace(pending_prefix + sanitized[:pending])
      text
    end

    def flush_codex_reasoning_delta(state, on_reasoning_delta: nil)
      pending = state[:pending_reasoning_delta].to_s
      state[:pending_reasoning_delta].clear
      text = sanitize_codex_reasoning_text(pending)
      append_codex_raw_reasoning_text(state, text, on_reasoning_delta: on_reasoning_delta) unless text.empty?
    end

    def split_trailing_comment_prefix(text)
      string = text.to_s
      prefix = ["<!-", "<!", "<"].find { |candidate| string.end_with?(candidate) }
      return [string, +""] unless prefix

      [string[0...-prefix.length], prefix.dup]
    end

    def sanitize_codex_reasoning_text(text, keep_incomplete_comment: false)
      string = text.to_s
      visible = +""
      index = 0

      while (start_index = string.index("<!--", index))
        end_index = string.index("-->", start_index + 4)
        if end_index
          visible << string[index...start_index]
          index = end_index + 3
        elsif keep_incomplete_comment
          visible << string[index...start_index]
          return { text: visible, pending: string[start_index..] }
        else
          visible << string[index..]
          index = string.length
        end
      end

      visible << string[index..].to_s
      visible = compact_blank_codex_reasoning_lines(visible)
      keep_incomplete_comment ? { text: visible, pending: +"" } : visible
    end

    def compact_blank_codex_reasoning_lines(text)
      text.to_s.gsub(/(?:[ \t]*\n){3,}/, "\n\n")
    end

    def compact_codex_reasoning_delta_spacing(existing, text)
      text = compact_blank_codex_reasoning_lines(text)
      trailing_newlines = existing.to_s[/\n+\z/].to_s.length
      leading_newlines = text[/\A\n+/].to_s.length
      excess_newlines = trailing_newlines + leading_newlines - 2
      return text unless excess_newlines.positive? && leading_newlines.positive?

      text[[excess_newlines, leading_newlines].min..].to_s
    end

    def codex_tool_arguments_delta(state, delta)
      item = active_codex_item(state)
      return unless item && ["function_call", "custom_tool_call"].include?(item["type"])

      key = item["type"] == "custom_tool_call" ? "input" : "arguments"
      item[key] = item[key].to_s + delta.to_s
    end

    def codex_tool_arguments_done(state, arguments)
      item = active_codex_item(state)
      return unless item&.fetch("type", nil) == "function_call"

      item["arguments"] = arguments.to_s
    end

    def codex_output_item_done(state, item, on_assistant_delta: nil, on_reasoning_delta: nil)
      return unless item.is_a?(Hash)

      item = merge_codex_item(active_or_known_codex_item(state, item), item)
      item = codex_visible_reasoning_item(state, item)
      remember_codex_item(state, item)
      collect_codex_item_output(state, item, on_assistant_delta: on_assistant_delta, on_reasoning_delta: on_reasoning_delta)
      state[:active_item_id] = nil if state[:active_item_id] == codex_item_key(item)
      state[:current_text_content_part] = nil
      state[:current_reasoning_content_part] = nil
    end

    def codex_visible_reasoning_item(state, item)
      return item unless item.is_a?(Hash) && item["type"] == "reasoning"

      visible = deep_dup_hash(item)
      sanitize_codex_reasoning_summary_item(visible)
      visible.delete("content") unless state[:show_raw_reasoning]
      return visible unless state[:show_raw_reasoning]
      return visible if visible["summary"].is_a?(Array) && !visible["summary"].empty?

      text = sanitize_codex_reasoning_text(raw_reasoning_from_codex_items([visible]))
      visible["summary"] = [{ "type" => "summary_text", "text" => text }] unless text.empty?
      visible
    end

    def sanitize_codex_reasoning_summary_item(item)
      return unless item["summary"].is_a?(Array)

      pending = +""
      item["summary"].each do |part|
        next unless part.is_a?(Hash) && part.key?("text")

        pending << part["text"].to_s
        sanitized = sanitize_codex_reasoning_text(pending, keep_incomplete_comment: true)
        part["text"] = sanitized[:text]
        pending.replace(sanitized[:pending])
      end
    end

    def collect_codex_item_output(state, item, on_assistant_delta: nil, on_reasoning_delta: nil)
      case item["type"]
      when "message"
        text = text_from_codex_items([item])
        return if text.empty?

        key = codex_item_key(item)
        if codex_commentary_message_item?(item)
          unless state[:emitted_message_keys].include?(key)
            on_reasoning_delta&.call(text)
            state[:emitted_message_keys] << key
          end
          return
        end
        return unless codex_streamable_message_item?(item)

        state[:content] << text
        unless state[:emitted_message_keys].include?(key)
          on_assistant_delta&.call(text)
          state[:emitted_message_keys] << key
        end
      when "reasoning"
        text = sanitize_codex_reasoning_text(reasoning_summary_from_codex_items([item]))
        if state[:reasoning_summary].empty? && !text.empty?
          state[:reasoning_summary] << text
          on_reasoning_delta&.call(text)
        end
      when "function_call", "custom_tool_call"
        tool_call = codex_tool_call(item)
        state[:tool_calls] << tool_call if tool_call && !state[:tool_calls].any? { |call| call["id"] == tool_call["id"] }
      end
    end

    def active_or_known_codex_item(state, item)
      key = codex_item_key(item)
      known = state[:items_by_id][key]
      return known if known

      active = active_codex_item(state)
      return active if active && (!codex_item_has_stable_key?(item) || codex_item_key(active) == key)

      nil
    end

    def codex_item_has_stable_key?(item)
      item.key?("id") || item.key?("call_id")
    end

    def active_codex_item(state)
      key = state[:active_item_id]
      key ? state[:items_by_id][key] : nil
    end

    def remember_codex_item(state, item)
      key = codex_item_key(item)
      if state[:items_by_id].key?(key)
        stored = state[:items_by_id][key]
        stored.replace(merge_codex_item(stored, item))
      else
        state[:items_by_id][key] = item
        state[:response_item_keys] << key
      end
    end

    def codex_item_key(item)
      item["id"] || item["call_id"] || "item_#{item.object_id}"
    end

    def merge_codex_item(existing, update)
      return deep_dup_hash(update) unless existing.is_a?(Hash)

      merged = deep_dup_hash(existing)
      update.each do |key, value|
        next if value.nil?

        merged[key] = if key == "content" && merged[key].is_a?(Array) && value.is_a?(Array)
                        value.empty? ? merged[key] : value
                      elsif key == "summary" && merged[key].is_a?(Array) && value.is_a?(Array)
                        value.empty? ? merged[key] : value
                      elsif key == "arguments" && value.to_s.empty? && !merged[key].to_s.empty?
                        merged[key]
                      else
                        deep_dup(value)
                      end
      end
      merged
    end

    def deep_dup_hash(hash)
      deep_dup(hash)
    end

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, entry), result| result[key] = deep_dup(entry) }
      when Array
        value.map { |entry| deep_dup(entry) }
      when String
        value.dup
      else
        value
      end
    end

    def codex_sse_message(state)
      message = { "role" => "assistant", "content" => codex_visible_content(state) }
      message["reasoning_summary"] = state[:reasoning_summary] unless state[:reasoning_summary].empty?
      message["tool_calls"] = state[:tool_calls] unless state[:tool_calls].empty?
      response_items = codex_response_items(state)
      message["response_items"] = response_items unless response_items.empty?
      message["usage"] = state[:usage] if state[:usage]
      message
    end

    def codex_visible_content(state)
      return state[:content] unless state[:content].empty?

      response_items = codex_response_items(state)
      visible_text = text_from_codex_items(visible_codex_message_items(response_items, tool_calls: state[:tool_calls]))
      return visible_text unless visible_text.empty?
      return "" unless state[:tool_calls].empty?

      state[:raw_content]
    end

    def visible_codex_message_items(items, tool_calls: [])
      messages = Array(items).select { |item| item.is_a?(Hash) && item["type"] == "message" }
      final_messages = messages.select { |item| codex_message_phase(item) == "final_answer" }
      return final_messages unless final_messages.empty?
      return [] unless tool_calls.empty?

      messages.reject { |item| codex_message_phase(item) == "commentary" }
    end

    def codex_streamable_message_item?(item)
      phase = codex_message_phase(item)
      phase.empty? || phase == "final_answer"
    end

    def codex_commentary_message_item?(item)
      codex_message_phase(item) == "commentary"
    end

    def codex_message_phase(item)
      item["phase"].to_s
    end

    def codex_response_items(state)
      state[:response_item_keys].filter_map { |key| state[:items_by_id][key] }
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

    def raw_reasoning_from_codex_items(items)
      items.flat_map do |item|
        next [] unless item.is_a?(Hash) && item["type"] == "reasoning" && item["content"].is_a?(Array)

        item["content"].filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "reasoning_text" }
      end.join
    end
  end
end
