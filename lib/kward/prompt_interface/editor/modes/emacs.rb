# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Emacs-style keymap for the built-in composer file editor.
    module EmacsEditorMode
      private

      def handle_emacs_key(key)
        return if handle_editor_bracketed_paste_key(key)

        if @editor_state.emacs_pending == "C-x"
          return handle_emacs_ctrl_x_key(key)
        end

        csi_result = handle_emacs_csi_u_key(key)
        return csi_result unless csi_result == false

        shift_result = handle_editor_shift_navigation_key(key)
        return shift_result unless shift_result == false

        editor_tab_result = handle_editor_tab_key(key)
        return editor_tab_result unless editor_tab_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        return true if handle_bundled_key(key) { |token| handle_emacs_key(token) }

        case key
        when "\n", "\r"
          return editor_search_confirm if editor_search_active?
          clear_editor_selection_before_edit
          editor_insert_newline
        when "\t"
          editor_insert_tab unless editor_search_active?
        when "\b", "\x7F"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_delete_character : editor_delete_before_cursor
        when TerminalKeys::CTRL_SPACE
          @editor_state.begin_selection unless editor_search_active?
        when TerminalKeys::CTRL_A
          @editor_state.move_line_start unless editor_search_active?
        when TerminalKeys::CTRL_B
          @editor_state.move_left unless editor_search_active?
        when TerminalKeys::CTRL_D
          @editor_state.delete_at_cursor unless editor_search_active?
        when TerminalKeys::CTRL_E
          @editor_state.move_line_end unless editor_search_active?
        when TerminalKeys::CTRL_F
          @editor_state.move_right unless editor_search_active?
        when "\x07"
          emacs_cancel
        when TerminalKeys::CTRL_K
          if editor_selection_active?
            emacs_kill_selection
          else
            @editor_state.kill_line_after_cursor unless editor_search_active?
          end
        when TerminalKeys::CTRL_N
          editor_move_down unless editor_search_active?
        when TerminalKeys::CTRL_P
          editor_move_up unless editor_search_active?
        when TerminalKeys::CTRL_R
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:backward)
        when TerminalKeys::CTRL_S
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:forward)
        when TerminalKeys::CTRL_U
          @editor_state.kill_line_before_cursor unless editor_search_active?
        when TerminalKeys::CTRL_V
          @editor_state.page_down(editor_page_rows) unless editor_search_active?
        when TerminalKeys::CTRL_W
          editor_selection_active? ? emacs_kill_selection : @editor_state.delete_word_before_cursor unless editor_search_active?
        when TerminalKeys::CTRL_X
          @editor_state.emacs_pending = "C-x"
          @editor_state.status = "C-x"
        when TerminalKeys::CTRL_Y
          @editor_state.yank_from_kill_ring unless editor_search_active?
        when "\e"
          return editor_search_cancel if editor_search_active?
          @editor_state.clear_selection
        when "\eb", "\eB"
          @editor_state.move_to_previous_word unless editor_search_active?
        when "\ed", "\eD"
          @editor_state.delete_word_after_cursor unless editor_search_active?
        when "\ef", "\eF"
          @editor_state.move_to_next_word unless editor_search_active?
        when "\ev", "\eV"
          @editor_state.page_up(editor_page_rows) unless editor_search_active?
        when "\ew", "\eW"
          emacs_copy_selection unless editor_search_active?
        when "\ey", "\eY"
          @editor_state.yank_pop unless editor_search_active?
        when "\e", "\e\x7F"
          @editor_state.delete_word_before_cursor unless editor_search_active?
        else
          ansi_result = handle_editor_modified_ansi_key(key)
          return ansi_result unless ansi_result == false

          key_name = key_name_for(key)
          named_result = handle_editor_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          if editor_search_active?
            editor_search_append(key) if printable_key?(key)
          elsif printable_key?(key)
            editor_insert_printable(key)
          end
        end
      end

      def handle_emacs_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence
        if editor_search_active?
          search_result = handle_editor_search_csi_u_key(sequence)
          return search_result unless search_result == false
        end

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        sequence = sequence.merge(remaining: "")
        normalized_code = ctrl_code(code)

        if ctrl_modifier?(modifier)
          case normalized_code
          when 13
            return false if editor_search_active?

            clear_editor_selection_before_edit
            editor_insert_endwise_modifier_newline
          when 32
            @editor_state.begin_selection unless editor_search_active?
          when 97
            @editor_state.move_line_start unless editor_search_active?
          when 98
            @editor_state.move_left unless editor_search_active?
          when 99, 103
            emacs_cancel
          when 100
            @editor_state.delete_at_cursor unless editor_search_active?
          when 101
            @editor_state.move_line_end unless editor_search_active?
          when 102
            @editor_state.move_right unless editor_search_active?
          when 107
            @editor_state.kill_line_after_cursor unless editor_search_active?
          when 110
            editor_move_down unless editor_search_active?
          when 112
            editor_move_up unless editor_search_active?
          when 114
            editor_search_active? ? editor_search_append(key) : editor_search_begin(:backward)
          when 115
            editor_search_active? ? editor_search_append(key) : editor_search_begin(:forward)
          when 118
            @editor_state.page_down(editor_page_rows) unless editor_search_active?
          when 119
            editor_selection_active? ? emacs_kill_selection : @editor_state.delete_word_before_cursor unless editor_search_active?
          when 120
            @editor_state.emacs_pending = "C-x"
            @editor_state.status = "C-x"
          when 121
            @editor_state.yank_from_kill_ring unless editor_search_active?
          else
            return false
          end
        elsif alt_modifier?(modifier)
          case normalized_code
          when 98
            @editor_state.move_to_previous_word unless editor_search_active?
          when 100
            @editor_state.delete_word_after_cursor unless editor_search_active?
          when 102
            @editor_state.move_to_next_word unless editor_search_active?
          when 118
            @editor_state.page_up(editor_page_rows) unless editor_search_active?
          when 119
            emacs_copy_selection unless editor_search_active?
          when 121
            @editor_state.yank_pop unless editor_search_active?
          else
            return false
          end
        elsif code == 9 && !ctrl_modifier?(modifier) && !alt_modifier?(modifier) && !super_modifier?(modifier)
          return false if editor_search_active?

          shift_modifier?(modifier) ? editor_outdent_tab : editor_insert_tab
        else
          handle_parsed_editor_csi_u_key(sequence)
        end
      end

      def handle_emacs_ctrl_x_key(key)
        @editor_state.emacs_pending = nil
        key = emacs_ctrl_x_csi_u_key(key)
        case key
        when TerminalKeys::CTRL_S
          save_editor
        when TerminalKeys::CTRL_C
          quit_editor("Unsaved changes. Press C-x C-c again to discard.")
        else
          @editor_state.status = "Unknown C-x command"
          true
        end
      end

      def emacs_ctrl_x_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return key unless sequence && ctrl_modifier?(sequence[:modifier])

        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        case ctrl_code(sequence[:code])
        when 99
          TerminalKeys::CTRL_C
        when 115
          TerminalKeys::CTRL_S
        else
          key
        end
      end

      def emacs_kill_selection
        return false unless editor_selection_active?

        range = @editor_state.selection_range
        @editor_state.cut_range(range[0], range[1])
        @editor_state.status = "Killed region"
        true
      end

      def emacs_copy_selection
        if editor_selection_active?
          range = @editor_state.selection_range
        elsif @editor_state.selection_anchor
          range = [@editor_state.selection_anchor, @editor_state.cursor + 1].minmax
        else
          return false
        end

        @editor_state.copy_for_kill_ring(range[0], range[1])
        @output_io.print(TerminalSequences.osc52(@editor_state.kill_buffer))
        @output_io.flush if @output_io.respond_to?(:flush)
        @editor_state.clear_selection
        @editor_state.status = "Copied region"
        true
      end

      def emacs_cancel
        if editor_search_active?
          editor_search_cancel
        else
          @editor_state.emacs_pending = nil
          @editor_state.clear_selection
          @editor_state.status = "Cancelled"
        end
        true
      end

    end
  end
end
