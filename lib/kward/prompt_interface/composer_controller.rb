# Namespace for the Kward CLI agent runtime.
module Kward
  # High-level composer input loop and submission controller.
  class PromptInterface
    # Text composer state transitions for keyboard input, paste, history, and submission.
    module ComposerController
      private

      def composer_input
        @composer.input
      end

      def composer_input=(value)
        @composer.input = value.to_s
      end

      def composer_cursor
        @composer.cursor
      end

      def composer_cursor=(value)
        @composer.cursor = value.to_i
      end

      def composer_attachments
        @composer.attachments
      end

      def composer_kill_buffer
        @composer.kill_buffer
      end

      def composer_kill_buffer=(value)
        @composer.kill_buffer = value.to_s
      end

      def insert_key(key)
        return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

        insert_string(key)
      end

      def insert_string(string)
        return if string.empty?

        reset_slash_selection
        reset_history_navigation
        @slash_overlay_dismissed_input = nil
              @composer.insert_string(string)
            end

      def insert_paste(string)
        parsed = parse_attachments(string)
        Array(parsed[:attachments]).each { |attachment| add_attachment(attachment) }
        insert_string(parsed[:text].to_s) unless parsed[:text].to_s.empty?
      end

      def parse_attachments(string)
        return { text: string.to_s, attachments: [] } unless @attachment_parser

        result = @attachment_parser.call(string.to_s)
        return { text: string.to_s, attachments: [] } unless result.is_a?(Hash)

        {
          text: result[:text] || result["text"] || "",
          attachments: result[:attachments] || result["attachments"] || []
        }
      rescue StandardError
        { text: string.to_s, attachments: [] }
      end

      def add_attachment(attachment)
              @composer.add_attachment(attachment)
            end

      def delete_before_cursor
              if @composer.cursor.zero?
          remove_last_attachment
          return
        end

        reset_slash_selection
        reset_history_navigation
        @composer.delete_before_cursor
            end

      def remove_last_attachment
              return unless @composer.remove_last_attachment

        reset_slash_selection
        reset_history_navigation
        @slash_overlay_dismissed_input = nil
            end

      def delete_at_cursor
              return unless @composer.cursor < @composer.input.length

        reset_slash_selection
        reset_history_navigation
        @slash_overlay_dismissed_input = nil
        @composer.delete_at_cursor
            end

      def move_cursor_left
              @composer.move_cursor_left
            end

      def move_cursor_right
              @composer.move_cursor_right
            end

      def move_to_start_of_line
              @composer.move_to_start_of_line
            end

      def move_to_end_of_line
              @composer.move_to_end_of_line
            end

      def move_to_previous_word
              @composer.move_to_previous_word
            end

      def move_to_next_word
              @composer.move_to_next_word
            end

      def delete_at_cursor_or_exit
        composer_input.empty? ? exit_input : delete_at_cursor
      end

      def delete_word_before_cursor
        reset_slash_selection
        reset_history_navigation
              @composer.delete_word_before_cursor
            end

      def delete_word_after_cursor
        reset_slash_selection
        reset_history_navigation
              @composer.delete_word_after_cursor
            end

      def kill_line_before_cursor
        reset_slash_selection
        reset_history_navigation
              @composer.kill_line_before_cursor
            end

      def kill_line_after_cursor
        reset_slash_selection
        reset_history_navigation
              @composer.kill_line_after_cursor
            end

      def kill_range(start_index, end_index)
              return unless @composer.kill_range(start_index, end_index)

        reset_slash_selection
        reset_history_navigation
            end

      def yank_kill_buffer
              @composer.yank_kill_buffer
            end

      def previous_word_boundary(index)
              @composer.previous_word_boundary(index)
      end

      def next_word_boundary(index)
              @composer.next_word_boundary(index)
      end

      def word_separator?(char)
        @composer.word_separator?(char)
      end

      def add_history(value)
              @composer.add_history(value)
            end

      def recall_previous_history
              @composer.recall_previous_history
            end

      def recall_next_history
              @composer.recall_next_history
            end

      def replace_input(value)
        @composer.replace_input(value)
            end

      def prefill_input(value)
        @mutex.synchronize do
          @composer.prefill_input = value.to_s
        end
      end

      def reset_history_navigation
              @composer.reset_history_navigation
            end


      def submit_input
        value = submitted_input
        add_history(composer_input)
        if @busy
          clear_prompt_for_output_locked
          self.composer_input = ""
          self.composer_cursor = 0
          @composer.clear_attachments
          reset_history_navigation
          @asking = true
          render_prompt_after_output_locked
        else
          clear_prompt_locked
          self.composer_input = ""
          self.composer_cursor = 0
          @composer.clear_attachments
          @asking = false
          @rendered_rows = 0
          @cursor_rendered_row = 0
        end
        @output_io.flush
        value
      end

      def submitted_input
        return composer_input if composer_attachments.empty?

        sources = composer_attachments.map { |attachment| attachment[:source_text].to_s }.reject(&:empty?)
        display_input = composer_input.to_s.rstrip
        full_input = [display_input, *sources].reject { |part| part.to_s.strip.empty? }.join("\n")
        SubmittedInput.new(full_input, display_input: display_input)
      end

      def exit_input
        if @busy
          clear_prompt_for_output_locked
          self.composer_input = ""
          self.composer_cursor = 0
          @composer.clear_attachments
          @asking = true
          render_prompt_after_output_locked
        else
          clear_prompt_locked
          self.composer_input = ""
          self.composer_cursor = 0
          @composer.clear_attachments
          @asking = false
          @rendered_rows = 0
          @cursor_rendered_row = 0
        end
        @output_io.flush
        EXIT_INPUT
      end

    end
  end
end
