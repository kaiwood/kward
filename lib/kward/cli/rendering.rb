# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Terminal rendering helpers for streamed assistant/tool output.
    module Rendering
      private

      def render_conversation_transcript(conversation)
        render_transcript_messages(conversation.messages)
      end

      def redraw_interactive_prompt
        tab = active_tab if respond_to?(:active_tab, true)
        clear_active_tab_transient_shell_output if tab && respond_to?(:clear_active_tab_transient_shell_output, true)
        if tab&.shell
          render_tab(tab, restore_composer: false)
          return
        end
        if tab&.running?
          @prompt.redraw if @prompt.respond_to?(:redraw)
          return
        end

        conversation = tab&.agent&.conversation || @footer_conversation
        unless conversation && @prompt.respond_to?(:restore_transcript)
          @prompt.redraw if @prompt.respond_to?(:redraw)
          return
        end

        restore_prompt_transcript do
          tab ? render_transcript_messages(tab.driver.messages) : render_conversation_transcript(conversation)
          render_tab_transient_shell_entries(tab) if tab && respond_to?(:render_tab_transient_shell_entries, true)
        end
      end

      # Renders a transcript supplied by either a Kward conversation or a
      # plugin-owned tab driver.
      def render_transcript_messages(messages)
        tool_calls_by_id = {}
        @prompt.say("\n#{colored("Transcript", :gray, :bold)}\n")
        Array(messages).each do |message|
          role = message_role(message)
          next if role == "system"

          case role
          when "user"
            print_user_transcript(
              CLITranscriptFormatter.user_transcript_input(message),
              display_input: CLITranscriptFormatter.user_display_text(message),
              attachment_references: CLITranscriptFormatter.image_references(message),
              image_parts: CLITranscriptFormatter.image_parts(message)
            )
          when "assistant"
            render_reasoning(message)
            render_assistant_message(message)
            message_tool_calls(message).each do |tool_call|
              tool_calls_by_id[tool_call_id(tool_call)] = tool_call
            end
          when "tool"
            render_tool_message(message, tool_calls_by_id)
          when "compactionSummary"
            render_transcript_block("Compaction summary", message_summary(message))
          else
            render_transcript_block(role.to_s.capitalize, CLITranscriptFormatter.content_text(message_content(message)))
          end
        end
      end

      def render_reasoning(message)
        CLITranscriptFormatter.reasoning_blocks(message).each do |reasoning|
          render_transcript_block("Reasoning", reasoning)
        end
      end

      def render_assistant_message(message)
        content = CLITranscriptFormatter.assistant_content_text(message)
        return if content.empty?

        render_transcript_block("Assistant", content)
      end

      def render_tool_message(message, tool_calls_by_id)
        tool_call = tool_calls_by_id[message_tool_call_id(message)] || CLITranscriptFormatter.synthetic_tool_call(message_name(message), message_tool_call_id(message))
        render_tool_result(tool_call, message_content(message).to_s)
      end

      def render_tool_result(tool_call, content)
        summary = limit_tool_output_lines(tool_result_summary(tool_call, content), INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT)
        if prompt_interface?
          print_tool_result(tool_call, content, line_limit: INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT)
        else
          @prompt.say("\n#{colored("Tool>", *tool_label_styles(content))} #{tool_summary_display_text(summary)}\n")
        end
      end

      def render_transcript_block(label, content)
        return if content.to_s.empty?

        rendered = render_markdown_transcript(content).sub(/\n+\z/, "")
        if prompt_interface?
          print_block_delta(label, rendered)
          finish_stream_block
        else
          @prompt.say("\n#{colored("#{transcript_label(label)}>", *label_styles(label))} #{rendered}\n")
        end
      end

      def render_markdown_transcript(content)
        ANSI.markdown(content, enabled: @color_enabled)
      end

      def render_blocking_turn_event(event, markdown_chunks, tool_line_limit: nil, update_diff: false)
        case event
        when Events::ReasoningDelta
          append_markdown_delta(markdown_chunks, "Reasoning", event.delta)
          :streamed
        when Events::ReasoningBoundary
          flush_markdown_deltas(markdown_chunks)
          :streamed
        when Events::AssistantDelta
          append_markdown_delta(markdown_chunks, "Assistant", event.delta)
          :assistant_streamed
        when Events::Retry
          flush_markdown_deltas(markdown_chunks)
          print_retry(event)
          :streamed
        when Events::ToolCall
          flush_markdown_deltas(markdown_chunks)
          :streamed
        when Events::ToolResult
          flush_markdown_deltas(markdown_chunks)
          update_session_diff(event.content, tool_call: event.tool_call) if update_diff
          print_tool_result(event.tool_call, event.content, line_limit: tool_line_limit)
          :streamed
        end
      end

      def append_markdown_delta(chunks, label, delta)
        text = delta.to_s
        return if text.empty?

        if chunks.last&.first == label
          chunks.last[1] << text
        else
          chunks << [label, +text]
        end
      end

      def flush_markdown_deltas(chunks, finish: true, streams: nil)
        wrote = false
        entries = ordered_markdown_entries(chunks.dup)
        if finish && streams
          streamed_labels = entries.map(&:first)
          entries = ordered_markdown_entries(entries.concat(streams.keys.reject { |label| streamed_labels.include?(label) }.map { |label| [label, ""] }))
        end

        entries.each do |label, content|
          next if content.empty? && !(finish && streams&.key?(label))

          rendered = if streams
            streams[label] ||= ANSI::MarkdownStream.new(enabled: @color_enabled)
            streams[label].render(content, final: finish)
          else
            render_markdown_transcript(content)
          end
          streams.delete(label) if finish && streams
          next if rendered.empty?

          print_block_delta(label, rendered)
          finish_stream_block if finish
          wrote = true
        end
        chunks.clear
        wrote
      end

      def ordered_markdown_entries(entries)
        labels = entries.map(&:first)
        return entries unless labels.include?("Reasoning") && labels.include?("Assistant")

        grouped = { "Reasoning" => +"", "Assistant" => +"" }
        others = []
        entries.each do |label, content|
          if grouped.key?(label)
            grouped[label] << content.to_s
          else
            others << [label, content]
          end
        end

        [["Reasoning", grouped["Reasoning"]], ["Assistant", grouped["Assistant"]]] + others
      end

      def message_role(message)
        MessageAccess.role(message)
      end

      def message_content(message)
        MessageAccess.content(message)
      end

      def message_summary(message)
        MessageAccess.summary(message) || message_content(message)
      end

      def message_name(message)
        MessageAccess.name(message)
      end

      def message_tool_call_id(message)
        MessageAccess.tool_call_id(message)
      end

      def message_tool_calls(message)
        MessageAccess.tool_calls(message)
      end

      def tool_call_id(tool_call)
        ToolCall.id(tool_call)
      end

      # Writes the user transcript output for the terminal CLI flow.
      def print_user_transcript(input, display_input: nil, attachment_references: nil, image_parts: nil)
        visible_input = display_input.nil? ? input : display_input
        write_prompt_transcript("\n#{colored("You>", :blue, :bold)} #{visible_input}\n")
        print_attachment_badges(input, references: attachment_references)
        print_pasted_images(input, image_parts: image_parts)
      end

      # Writes the attachment badges output for the terminal CLI flow.
      def print_attachment_badges(input, references: nil)
        badges = references ? Array(references).map { |reference| attachment_badge_text(reference) } : composer_attachment_badges(input)
        return if badges.empty?

        write_prompt_transcript("#{badges.join("\n")}\n")
      end

      def write_prompt_transcript(message)
        if @prompt.respond_to?(:write_transcript)
          @prompt.write_transcript(message)
        else
          @prompt.say(message)
        end
      end

      def composer_attachment_badges(input, attachments = [])
        references = Array(attachments)
        references = Kward::ImageAttachments.references_from_text(input) if references.empty?
        references.map { |reference| attachment_badge_text(reference) }
      end

      def composer_attachment_parser(input)
        Kward::ImageAttachments.extract_references_from_text(input)
      end

      def submitted_display_input(input)
        input.respond_to?(:display_input) ? input.display_input : nil
      end

      def attachment_badge_text(reference)
        status = reference[:status] || reference["status"]
        label = reference[:label] || reference["label"] || "image"
        if status == :missing || status.to_s == "missing"
          "[image?] #{label} not found"
        else
          media_type = reference[:media_type] || reference["media_type"] || reference[:mimeType] || reference["mimeType"] || "image"
          size = format_attachment_size(reference[:size_bytes] || reference["size_bytes"] || reference[:sizeBytes] || reference["sizeBytes"])
          "[image] #{label} · #{media_type}#{size.empty? ? "" : " · #{size}"}"
        end
      end

      def format_attachment_size(bytes)
        value = bytes.to_i
        return "" unless value.positive?
        return "#{value} B" if value < 1024

        units = %w[KB MB GB]
        size = value.to_f / 1024
        unit = units.shift
        while size >= 1024 && units.any?
          size /= 1024
          unit = units.shift
        end
        formatted = size >= 10 ? size.round.to_s : format("%.1f", size).sub(/\.0\z/, "")
        "#{formatted} #{unit}"
      end

      # Writes the pasted images output for the terminal CLI flow.
      def print_pasted_images(input, image_parts: nil)
        parts = image_parts || Kward::ImageAttachments.image_parts_from_text(input)
        parts.each do |part|
          sequence = Kward::ImageAttachments.terminal_image_sequence(part)
          next unless sequence

          if @prompt.respond_to?(:say_visual)
            @prompt.say_visual(sequence)
          else
            @prompt.say(sequence)
          end
        end
      end

      # Writes the block delta output for the terminal CLI flow.
      def print_block_delta(label, delta)
        if prompt_interface?
          if @prompt.respond_to?(:write_stream_block)
            @prompt.write_stream_block(label, delta, finish: false)
          else
            @prompt.start_stream_block(label)
            @prompt.write_delta(delta)
          end
        else
          start_stream_block(label)
          print delta
          $stdout.flush
        end
      end

      # Writes the retry output for the terminal CLI flow.
      def print_retry(event)
        message = retry_message(event)
        if prompt_interface?
          if @prompt.respond_to?(:write_stream_block)
            @prompt.write_stream_block("Retry", "#{message}\n", finish: true)
          else
            @prompt.start_stream_block("Retry")
            @prompt.write_delta("#{message}\n")
            @prompt.finish_stream_block
          end
        else
          start_stream_block("Retry")
          puts message
          $stdout.flush
          @stream_block = nil
        end
      end

      def retry_message(event)
        RetryMessage.format(event)
      end

      # Writes the tool result output for the terminal CLI flow.
      def print_tool_result(tool_call, content, line_limit: nil)
        summary = tool_result_summary(tool_call, content)
        summary = limit_tool_output_lines(summary, line_limit) if line_limit
        display_summary = tool_summary_display_text(summary)
        if prompt_interface?
          summary = display_summary.end_with?("\n") ? display_summary : "#{display_summary}\n"
          if @prompt.respond_to?(:write_stream_block)
            @prompt.write_stream_block("Tool", summary, finish: true)
          else
            @prompt.start_stream_block("Tool")
            @prompt.write_delta(summary)
            @prompt.finish_stream_block
          end
        else
          start_stream_block(tool_stream_label(content))
          print display_summary
          puts unless display_summary.end_with?("\n")
          $stdout.flush
          @stream_block = nil
        end
      end

      def tool_summary_display_text(summary)
        text = summary.to_s
        return text if text.start_with?("read_skill:\n")

        text.sub("\n", "\n\n")
      end

      def start_stream_block(label)
        return if @stream_block == label

        puts if @stream_block
        print "\n#{colored("#{transcript_label(label)}>", *label_styles(label))} "
        @stream_block = label
      end

      def finish_stream_block
        if prompt_interface?
          @prompt.finish_stream_block
        else
          puts if @stream_block
          @stream_block = nil
        end
      end

      def colored(text, *styles)
        ANSI.colorize(text, *styles, enabled: @color_enabled)
      end

      def transcript_label(label)
        case label
        when "Assistant"
          assistant_prompt_name
        when "Tool failed"
          "Tool"
        else
          label
        end
      end

      def label_styles(label)
        case label
        when "Reasoning", "Compaction summary"
          [:gray, :bold]
        when "Assistant", "Kward"
          [:green, :bold]
        when "Tool", "Tool output"
          [:cyan, :bold]
        when "Tool failed"
          [:red, :bold]
        when "Retry"
          [:yellow, :bold]
        else
          [:gray, :bold]
        end
      end

      def tool_stream_label(content)
        tool_result_failed?(content) ? "Tool failed" : "Tool"
      end

      def tool_label_styles(content)
        label_styles(tool_stream_label(content))
      end

    end
  end
end
