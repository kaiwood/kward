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

        multi_cursor_result = handle_modern_multi_cursor_key(key)
        return multi_cursor_result unless multi_cursor_result == false

        indentation_navigation_result = handle_modern_indentation_navigation_key(key)
        return indentation_navigation_result unless indentation_navigation_result == false

        modified_navigation_result = handle_modern_modified_navigation_key(key)
        return modified_navigation_result unless modified_navigation_result == false

        shift_result = handle_editor_shift_navigation_key(key)
        return shift_result unless shift_result == false

        binding_result = handle_modern_key_binding(key)
        return binding_result unless binding_result == false

        editor_tab_result = handle_editor_tab_key(key) { |direction| modern_record_undo { direction == :forward ? editor_insert_tab : editor_outdent_tab } }
        return editor_tab_result unless editor_tab_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        return true if handle_bundled_key(key) { |token| handle_modern_key(token) }

        case key
        when "\n", "\r"
          return editor_search_confirm if editor_search_active?
          modern_record_undo { modern_insert_text("\n") }
        when "\t"
          modern_record_undo { editor_insert_tab unless editor_search_active? }
        when "\b", "\x7F"
          editor_search_active? ? editor_search_delete_character : modern_record_undo { modern_delete_before_cursor }
        when TerminalKeys::CTRL_C
          return editor_search_cancel if editor_search_active?
        when "\e"
          return editor_search_cancel if editor_search_active?
          return @editor_state.collapse_to_primary_selection if @editor_state.multi_cursor?
          return @editor_state.clear_selection if @editor_state.selection_active?
        when "/"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:forward)
        when "?"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:backward)
        when TerminalKeys::CTRL_Q
          quit_editor
        when TerminalKeys::CTRL_S
          save_editor
        when TerminalKeys::CTRL_Z
          @editor_state.undo unless editor_search_active?
        else
          key_name = key_name_for(key)
          named_result = handle_editor_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          if editor_search_active?
            editor_search_append(key) if printable_key?(key)
          elsif printable_key?(key)
            modern_record_undo { modern_insert_printable(key) }
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

      def handle_modern_multi_cursor_key(key)
        return false if editor_search_active?

        case key
        when TerminalKeys::CTRL_D
          @editor_state.add_next_occurrence_selection
        when *TerminalKeys::ALT_SHIFT_UP
          @editor_state.add_vertical_cursor(:up)
        when *TerminalKeys::ALT_SHIFT_DOWN
          @editor_state.add_vertical_cursor(:down)
        else
          false
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
          TerminalKeys::ALT_UP
        when [:alt, :down]
          TerminalKeys::ALT_DOWN
        when [:alt, :right]
          TerminalKeys::ALT_RIGHT
        when [:alt, :select_up]
          TerminalKeys::ALT_SHIFT_UP
        when [:alt, :select_down]
          TerminalKeys::ALT_SHIFT_DOWN
        when [:alt, :select_right]
          TerminalKeys::ALT_SHIFT_RIGHT
        when [:ctrl, :up]
          TerminalKeys::CTRL_UP
        when [:ctrl, :down]
          TerminalKeys::CTRL_DOWN
        when [:ctrl, :right]
          TerminalKeys::CTRL_RIGHT
        when [:ctrl, :select_up]
          TerminalKeys::CTRL_SHIFT_UP
        when [:ctrl, :select_down]
          TerminalKeys::CTRL_SHIFT_DOWN
        when [:ctrl, :select_right]
          TerminalKeys::CTRL_SHIFT_RIGHT
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
        when *TerminalKeys::CTRL_RIGHT
          @editor_state.move_line_end
        when *TerminalKeys::CTRL_LEFT
          @editor_state.move_line_start
        when *TerminalKeys::CTRL_UP
          @editor_state.move_file_start
        when *TerminalKeys::CTRL_DOWN
          @editor_state.move_file_end
        when *TerminalKeys::ALT_SHIFT_RIGHT
          editor_extending_selection { @editor_state.move_to_next_word }
        when *TerminalKeys::ALT_SHIFT_LEFT
          editor_extending_selection { @editor_state.move_to_previous_word }
        else
          false
        end
      end

      def handle_modern_key_binding(key)
        case key
        when TerminalKeys::CTRL_SPACE
          true
        when TerminalKeys::CTRL_C
          editor_search_active? ? editor_search_cancel : copy_editor_selection
        when TerminalKeys::CTRL_F
          @editor_state.move_right unless editor_search_active?
        when TerminalKeys::CTRL_V
          modern_record_undo { @editor_state.yank_kill_buffer } unless editor_search_active?
        when TerminalKeys::CTRL_X
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
        when 100
          return false if editor_search_active?

          @editor_state.add_next_occurrence_selection
        when 102
          @editor_state.move_right unless editor_search_active?
        when 118
          modern_record_undo { @editor_state.yank_kill_buffer } unless editor_search_active?
        when 120
          modern_record_undo { cut_editor_selection } unless editor_search_active?
        when 108
          return false if editor_search_active?
          return false unless modern_ctrl_shift_key?(code, modifier)

          @editor_state.selection_to_line_start_cursors
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
        when TerminalKeys::CTRL_D, TerminalKeys::CTRL_K, TerminalKeys::CTRL_U, TerminalKeys::CTRL_W, TerminalKeys::CTRL_Y, *TerminalKeys::DELETE, "\ed", "\eD", "\e\b", "\e\x7F"
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
          return @editor_state.add_next_occurrence_selection if normalized_code == 100
          if normalized_code == 108 && modern_ctrl_shift_key?(code, modifier)
            return @editor_state.selection_to_line_start_cursors
          end

          case normalized_code
          when 107, 117, 119, 121
            return modern_record_undo { handle_parsed_editor_csi_u_key(sequence) }
          end
        end

        case code
        when 9
          return false if editor_search_active?
          return false if ctrl_modifier?(modifier) || alt_modifier?(modifier) || super_modifier?(modifier)

          shift_modifier?(modifier) ? modern_record_undo { editor_outdent_tab } : modern_record_undo { editor_insert_tab }
        when 13
          return editor_search_confirm if editor_search_active?

          modern_record_undo { modern_insert_text("\n") }
        when 8, 127
          editor_search_active? ? editor_search_delete_character : modern_record_undo { modern_delete_before_cursor }
        when 4
          modern_record_undo { delete_editor_selection || @editor_state.delete_at_cursor } unless editor_search_active?
        else
          text = csi_u_printable_text(sequence)
          if text
            editor_search_active? ? editor_search_append(text) : modern_record_undo { modern_insert_printable(text) }
          elsif csi_u_text_field?(sequence)
            true
          else
            handle_parsed_editor_csi_u_key(sequence)
          end
        end
      end

      def handle_modern_bracketed_paste_key(key)
        handle_bracketed_paste(key) do |content|
          modern_record_undo { @editor_state.insert(content) } unless editor_search_active?
        end
      end

      def modern_insert_printable(text)
        return editor_insert_printable(text) unless @editor_state.multi_cursor?

        @editor_state.replace_selections(text)
      end

      def modern_insert_text(text)
        return @editor_state.replace_selections(text) if @editor_state.multi_cursor? || @editor_state.selection_ranges.any?

        if text == "\n"
          editor_insert_newline
        else
          @editor_state.insert(text)
        end
      end

      def modern_delete_before_cursor
        return @editor_state.delete_before_selections if @editor_state.multi_cursor?

        delete_editor_selection || editor_delete_before_cursor
      end

      def modern_record_undo
        before_buffer = @editor_state.buffer.dup
        before_redo_stack = @editor_state.redo_stack.map { |entry| entry.merge(buffer: entry[:buffer].dup, selections: entry[:selections]&.map(&:dup)) }
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
