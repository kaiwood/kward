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
      when "WebFetch" then "fetch_content"
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
      {
        content: +"",
        raw_content: +"",
        emitted_message_keys: [],
        reasoning_summary: +"",
        tool_calls: [],
        response_item_keys: [],
        items_by_id: {},
        active_item_id: nil,
        current_text_content_part: nil,
        usage: nil
      }
    end

    def process_codex_sse_block(block, state, on_reasoning_delta: nil, on_assistant_delta: nil, usage_normalizer: nil, request_error_class: nil)
      data = block.lines.filter_map { |line| line.start_with?("data:") ? line.delete_prefix("data:").strip : nil }.join("\n")
      return if data.empty? || data == "[DONE]"

      event = JSON.parse(data)
      case event["type"]
      when "response.output_item.added"
        codex_output_item_added(state, event["item"])
      when "response.content_part.added"
        codex_content_part_added(state, event["part"])
      when "response.output_text.delta", "response.refusal.delta"
        codex_output_text_delta(state, event["delta"], on_assistant_delta: on_assistant_delta)
      when "response.reasoning_summary_part.added"
        codex_reasoning_summary_part_added(state, event["part"])
      when "response.reasoning_summary_text.delta"
        codex_reasoning_delta(state, event["delta"], on_reasoning_delta: on_reasoning_delta)
      when "response.reasoning_summary_part.done"
        codex_reasoning_part_done(state, on_reasoning_delta: on_reasoning_delta)
      when "response.reasoning_text.delta"
        codex_reasoning_delta(state, event["delta"], on_reasoning_delta: on_reasoning_delta)
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

    def codex_output_item_added(state, item)
      return unless item.is_a?(Hash)

      item = deep_dup_hash(item)
      item["content"] = [] if item["type"] == "message" && !item["content"].is_a?(Array)
      item["summary"] = [] if item["type"] == "reasoning" && !item["summary"].is_a?(Array)
      remember_codex_item(state, item)
      state[:active_item_id] = codex_item_key(item)
      state[:current_text_content_part] = nil
    end

    def codex_content_part_added(state, part)
      item = active_codex_item(state)
      return unless item&.fetch("type", nil) == "message" && part.is_a?(Hash)
      return unless ["output_text", "text", "refusal"].include?(part["type"])

      item["content"] ||= []
      item["content"] << deep_dup_hash(part)
      state[:current_text_content_part] = item["content"].last
    end

    def codex_output_text_delta(state, delta, on_assistant_delta: nil)
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
      end
      state[:raw_content] << text
    end

    def codex_reasoning_summary_part_added(state, part)
      item = active_codex_item(state)
      return unless item&.fetch("type", nil) == "reasoning" && part.is_a?(Hash)

      item["summary"] ||= []
      item["summary"] << deep_dup_hash(part)
    end

    def codex_reasoning_delta(state, delta, on_reasoning_delta: nil)
      text = delta.to_s
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

    def codex_reasoning_part_done(state, on_reasoning_delta: nil)
      item = active_codex_item(state)
      return unless item&.fetch("type", nil) == "reasoning"
      return if item["summary"].to_a.empty?

      text = "\n\n"
      item["summary"].last["text"] = item["summary"].last["text"].to_s + text
      state[:reasoning_summary] << text
      on_reasoning_delta&.call(text)
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
      remember_codex_item(state, item)
      collect_codex_item_output(state, item, on_assistant_delta: on_assistant_delta, on_reasoning_delta: on_reasoning_delta)
      state[:active_item_id] = nil if state[:active_item_id] == codex_item_key(item)
      state[:current_text_content_part] = nil
    end

    def collect_codex_item_output(state, item, on_assistant_delta: nil, on_reasoning_delta: nil)
      case item["type"]
      when "message"
        text = text_from_codex_items([item])
        return if text.empty? || !codex_streamable_message_item?(item)

        state[:content] << text
        key = codex_item_key(item)
        unless state[:emitted_message_keys].include?(key)
          on_assistant_delta&.call(text)
          state[:emitted_message_keys] << key
        end
      when "reasoning"
        text = reasoning_summary_from_codex_items([item])
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
      codex_message_phase(item) == "final_answer"
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
  end
end
