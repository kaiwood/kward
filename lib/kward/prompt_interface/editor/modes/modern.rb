# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Modern keymap for the built-in composer file editor.
    module ModernEditorMode
      private

      def handle_modern_key(key)
        return if handle_modern_bracketed_paste_key(key)

        csi_result = handle_modern_csi_u_key(key)
        return csi_result unless csi_result == false

        indentation_navigation_result = handle_modern_indentation_navigation_key(key)
        return indentation_navigation_result unless indentation_navigation_result == false

        modified_navigation_result = handle_modern_modified_navigation_key(key)
        return modified_navigation_result unless modified_navigation_result == false

        shift_result = handle_editor_shift_navigation_key(key)
        return shift_result unless shift_result == false

        binding_result = handle_modern_key_binding(key)
        return binding_result unless binding_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_modern_key(token)
          end
        end

        case key
        when "\n", "\r"
          return editor_search_confirm if editor_search_active?
          modern_record_undo do
            clear_editor_selection_before_edit
            editor_insert_newline
          end
        when "\t"
          modern_record_undo do
            clear_editor_selection_before_edit
            @editor_state.insert("  ") unless editor_search_active?
          end
        when "\b", "\x7F"
          editor_search_active? ? editor_search_delete_character : modern_record_undo { delete_editor_selection || editor_delete_before_cursor }
        when "\x03"
          return editor_search_cancel if editor_search_active?
        when "\e"
          return editor_search_cancel if editor_search_active?
          return @editor_state.clear_selection if @editor_state.selection_active?
        when "/"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:forward)
        when "?"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:backward)
        when "\x11"
          quit_editor
        when "\x13"
          save_editor
        when "\x1A"
          @editor_state.undo unless editor_search_active?
        else
          key_name = key_name_for(key)
          named_result = handle_editor_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          if editor_search_active?
            editor_search_append(key) if printable_key?(key)
          elsif printable_key?(key)
            modern_record_undo { editor_insert_printable(key) }
          end
        end
      end

      def handle_modern_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        sequence = sequence.merge(remaining: "")

        if ctrl_modifier?(modifier) || super_modifier?(modifier)
          handle_modern_modified_key(code, modifier, sequence)
        else
          handle_modern_editor_csi_u_key(sequence)
        end
      end

      def handle_modern_indentation_navigation_key(key)
        return false if editor_search_active?

        case key
        when *modern_indentation_key_sequences(:up)
          modern_move_indentation { @editor_state.move_indentation_up }
        when *modern_indentation_key_sequences(:down)
          modern_move_indentation { @editor_state.move_indentation_down }
        when *modern_indentation_key_sequences(:right)
          modern_move_indentation { @editor_state.move_indentation_right }
        when *modern_indentation_key_sequences(:select_up)
          editor_extending_selection { @editor_state.move_indentation_up }
        when *modern_indentation_key_sequences(:select_down)
          editor_extending_selection { @editor_state.move_indentation_down }
        when *modern_indentation_key_sequences(:select_right)
          editor_extending_selection { @editor_state.move_indentation_right }
        else
          false
        end
      end

      def modern_move_indentation
        result = yield
        @editor_state.clear_selection
        result
      end

      def modern_indentation_key_sequences(action)
        case [modern_indentation_modifier, action]
        when [:alt, :up]
          ["\e[1;3A", "\e[3A"]
        when [:alt, :down]
          ["\e[1;3B", "\e[3B"]
        when [:alt, :right]
          ["\e[1;3C", "\e[3C"]
        when [:alt, :select_up]
          ["\e[1;4A", "\e[4A"]
        when [:alt, :select_down]
          ["\e[1;4B", "\e[4B"]
        when [:alt, :select_right]
          ["\e[1;4C", "\e[4C"]
        when [:ctrl, :up]
          ["\e[1;5A", "\e[5A"]
        when [:ctrl, :down]
          ["\e[1;5B", "\e[5B"]
        when [:ctrl, :right]
          ["\e[1;5C", "\e[5C"]
        when [:ctrl, :select_up]
          ["\e[1;6A", "\e[6A"]
        when [:ctrl, :select_down]
          ["\e[1;6B", "\e[6B"]
        when [:ctrl, :select_right]
          ["\e[1;6C", "\e[6C"]
        else
          []
        end
      end

      def modern_indentation_modifier
        RbConfig::CONFIG["host_os"].to_s.downcase.include?("darwin") ? :alt : :ctrl
      end

      def handle_modern_modified_navigation_key(key)
        return false if editor_search_active?

        case key
        when "\e[1;5C", "\e[5C"
          @editor_state.move_line_end
        when "\e[1;5D", "\e[5D"
          @editor_state.move_line_start
        when "\e[1;5A", "\e[5A"
          @editor_state.move_file_start
        when "\e[1;5B", "\e[5B"
          @editor_state.move_file_end
        when "\e[1;4C", "\e[4C"
          editor_extending_selection { @editor_state.move_to_next_word }
        when "\e[1;4D", "\e[4D"
          editor_extending_selection { @editor_state.move_to_previous_word }
        else
          false
        end
      end

      def handle_modern_key_binding(key)
        case key
        when "\x00"
          true
        when "\x03"
          editor_search_active? ? editor_search_cancel : copy_editor_selection
        when "\x06"
          @editor_state.move_right unless editor_search_active?
        when "\x16"
          modern_record_undo { @editor_state.yank_kill_buffer } unless editor_search_active?
        when "\x18"
          modern_record_undo { cut_editor_selection } unless editor_search_active?
        else
          handle_modern_shared_key_binding(key)
        end
      end

      def handle_modern_modified_key(code, modifier, sequence)
        normalized_code = ctrl_code(code)
        if super_modifier?(modifier)
          return editor_search_active? ? editor_search_cancel : copy_editor_selection if normalized_code == 99
          return handle_modern_editor_csi_u_key(sequence) unless ctrl_modifier?(modifier)
        end

        case normalized_code
        when 13
          return false if editor_search_active?

          modern_record_undo do
            clear_editor_selection_before_edit
            editor_insert_endwise_modifier_newline
          end
        when 99
          editor_search_active? ? editor_search_cancel : copy_editor_selection
        when 102
          @editor_state.move_right unless editor_search_active?
        when 118
          modern_record_undo { @editor_state.yank_kill_buffer } unless editor_search_active?
        when 120
          modern_record_undo { cut_editor_selection } unless editor_search_active?
        when 122
          return if editor_search_active?

          modern_ctrl_shift_key?(code, modifier) ? @editor_state.redo : @editor_state.undo
        else
          return false if normalized_code == 32

          handle_modern_editor_csi_u_key(sequence)
        end
      end

      def handle_modern_shared_key_binding(key)
        case key
        when "\x04", "\x0B", "\x15", "\x17", "\x19", "\e[3~", "\ed", "\eD", "\e\b", "\e\x7F"
          modern_record_undo { handle_editor_key_binding(key) }
        else
          handle_editor_key_binding(key)
        end
      end

      def handle_modern_editor_csi_u_key(key_or_sequence)
        sequence = key_or_sequence.is_a?(Hash) ? key_or_sequence : parse_csi_u_key(key_or_sequence)
        return handle_editor_csi_u_key(key_or_sequence) unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        if ctrl_modifier?(modifier)
          normalized_code = ctrl_code(code)
          case normalized_code
          when 100, 107, 117, 119, 121
            return modern_record_undo { handle_parsed_editor_csi_u_key(sequence) }
          end
        end

        case code
        when 13, 8, 127, 4
          modern_record_undo { handle_parsed_editor_csi_u_key(sequence) }
        else
          if !sequence[:text].to_s.empty? || ((sequence[:modifiers].to_s.empty? || sequence[:modifiers].to_s == "1") && code.between?(32, 126))
            modern_record_undo { handle_parsed_editor_csi_u_key(sequence) }
          else
            handle_parsed_editor_csi_u_key(sequence)
          end
        end
      end

      def handle_modern_bracketed_paste_key(key)
        paste = read_bracketed_paste(key)
        return false unless paste

        modern_record_undo { @editor_state.insert(normalize_paste(paste[:content])) } unless editor_search_active?
        queue_pending_keys(paste[:remaining]) if paste[:remaining] && !paste[:remaining].empty?
        true
      end

      def modern_record_undo
        before_buffer = @editor_state.buffer.dup
        before_redo_stack = @editor_state.redo_stack.map { |entry| { buffer: entry[:buffer].dup, cursor: entry[:cursor] } }
        @editor_state.push_undo
        result = yield
        if @editor_state.buffer == before_buffer
          @editor_state.undo_stack.pop
          @editor_state.redo_stack = before_redo_stack
        end
        result
      end

      def modern_ctrl_shift_key?(code, modifier)
        code.to_i.between?(65, 90) || ((modifier.to_i - 1) & 1).positive?
      end
    end
  end
end
