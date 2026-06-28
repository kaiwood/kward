# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Readline-style insert-mode bindings for the Vibe editor mode.
    module VibeInsertReadline
      private

      def handle_vibe_insert_readline_key(key)
        csi_result = handle_vibe_insert_readline_csi_u_key(key)
        return csi_result unless csi_result == false

        handle_vibe_insert_readline_ansi_key(key)
      end

      def handle_vibe_insert_readline_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        modifier = sequence[:modifier]
        normalized_code = sequence[:code].to_i.chr.downcase.ord rescue sequence[:code]
        if ctrl_modifier?(modifier)
          return handle_vibe_insert_readline_ctrl_key(normalized_code)
        elsif alt_modifier?(modifier)
          return handle_vibe_insert_readline_alt_key(normalized_code)
        end

        false
      end

      def handle_vibe_insert_readline_ansi_key(key)
        case key
        when TerminalKeys::CTRL_A
          @editor_state.move_line_start
        when TerminalKeys::CTRL_B
          @editor_state.move_left
        when TerminalKeys::CTRL_D
          vibe_record_undo { @editor_state.delete_at_cursor }
        when TerminalKeys::CTRL_E
          @editor_state.move_line_end
        when TerminalKeys::CTRL_F
          @editor_state.move_right
        when TerminalKeys::CTRL_K
          vibe_record_undo { @editor_state.kill_line_after_cursor }
        when TerminalKeys::CTRL_U
          vibe_record_undo { @editor_state.kill_line_before_cursor }
        when TerminalKeys::CTRL_W
          vibe_record_undo { @editor_state.delete_word_before_cursor }
        when TerminalKeys::CTRL_Y
          vibe_record_undo { @editor_state.yank_kill_buffer }
        when *TerminalKeys::LEFT
          @editor_state.move_left
        when *TerminalKeys::RIGHT
          @editor_state.move_right
        when *TerminalKeys::HOME
          @editor_state.move_line_start
        when *TerminalKeys::END_KEY
          @editor_state.move_line_end
        when *TerminalKeys::DELETE
          vibe_record_undo { @editor_state.delete_at_cursor }
        when "\eb", "\eB"
          @editor_state.move_to_previous_word
        when "\ef", "\eF"
          @editor_state.move_to_next_word
        when "\ed", "\eD"
          vibe_record_undo { @editor_state.delete_word_after_cursor }
        when "\e\b", "\e\x7F"
          vibe_record_undo { @editor_state.delete_word_before_cursor }
        else
          handle_vibe_insert_modified_ansi_key(key)
        end
      end

      def handle_vibe_insert_readline_ctrl_key(normalized_code)
        case normalized_code
        when 97
          @editor_state.move_line_start
        when 98
          @editor_state.move_left
        when 100
          vibe_record_undo { @editor_state.delete_at_cursor }
        when 101
          @editor_state.move_line_end
        when 102
          @editor_state.move_right
        when 107
          vibe_record_undo { @editor_state.kill_line_after_cursor }
        when 117
          vibe_record_undo { @editor_state.kill_line_before_cursor }
        when 119
          vibe_record_undo { @editor_state.delete_word_before_cursor }
        when 121
          vibe_record_undo { @editor_state.yank_kill_buffer }
        else
          false
        end
      end

      def handle_vibe_insert_readline_alt_key(normalized_code)
        case normalized_code
        when 98
          @editor_state.move_to_previous_word
        when 100
          vibe_record_undo { @editor_state.delete_word_after_cursor }
        when 102
          @editor_state.move_to_next_word
        else
          false
        end
      end

      def handle_vibe_insert_modified_ansi_key(key)
        sequence = parse_modified_ansi_key(key)
        return false unless sequence

        case sequence[:type]
        when :cursor
          return false unless alt_modifier?(sequence[:modifier])

          case sequence[:final]
          when "C"
            @editor_state.move_to_next_word
          when "D"
            @editor_state.move_to_previous_word
          when "F"
            @editor_state.move_line_end
          when "H"
            @editor_state.move_line_start
          else
            false
          end
        when :delete
          return false unless alt_modifier?(sequence[:modifier])

          vibe_record_undo { @editor_state.delete_word_after_cursor }
        else
          false
        end
      end

      def handle_vibe_insert_named_key(key_name)
        case key_name
        when :escape
          vibe_return_to_normal
        when :return, :enter
          vibe_record_undo { editor_insert_newline }
        when :backspace
          vibe_record_undo { editor_delete_before_cursor }
        when :delete
          vibe_record_undo { @editor_state.delete_at_cursor }
        when :left
          @editor_state.move_left
        when :right
          @editor_state.move_right
        when :up
          editor_move_up
        when :down
          editor_move_down
        else
          false
        end
      end
    end
  end
end
