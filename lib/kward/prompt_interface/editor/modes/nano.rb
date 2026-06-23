# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Nano-style keymap for the built-in composer file editor.
    module NanoEditorMode
      private

      def handle_nano_key(key)
        return if handle_editor_bracketed_paste_key(key)

        csi_result = handle_nano_csi_u_key(key)
        return csi_result unless csi_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_nano_key(token)
          end
        end

        case key
        when "\n", "\r"
          return editor_search_confirm if editor_search_active?
          clear_editor_selection_before_edit
          @editor_state.insert("\n")
        when "\t"
          clear_editor_selection_before_edit
          @editor_state.insert("  ") unless editor_search_active?
        when "\b", "\x7F"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_delete_character : @editor_state.delete_before_cursor
        when "\x03", "\e"
          return editor_search_cancel if editor_search_active?
          @editor_state.clear_selection
        when "\x01"
          @editor_state.move_line_start unless editor_search_active?
        when "\x05"
          @editor_state.move_line_end unless editor_search_active?
        when "\x0B"
          nano_cut_selection_or_line unless editor_search_active?
        when "\x0F"
          save_editor
        when "\x15"
          @editor_state.yank_kill_buffer unless editor_search_active?
        when "\x16"
          @editor_state.page_down(editor_page_rows) unless editor_search_active?
        when "\x17"
          editor_search_active? ? editor_search_append(key) : editor_search_begin
        when "\x18"
          quit_editor("Unsaved changes. Press Ctrl+X again to discard.")
        when "\x19"
          @editor_state.page_up(editor_page_rows) unless editor_search_active?
        when "\x1E"
          @editor_state.begin_selection unless editor_search_active?
        when "\e6"
          nano_copy_selection unless editor_search_active?
        else
          key_name = key_name_for(key)
          named_result = handle_editor_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          if editor_search_active?
            editor_search_append(key) if printable_key?(key)
          elsif printable_key?(key)
            clear_editor_selection_before_edit
            @editor_state.insert(key)
          end
        end
      end

      def handle_nano_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        if ctrl_modifier?(modifier)
          normalized_code = ctrl_code(code)
          case normalized_code
          when 1, 97
            @editor_state.move_line_start unless editor_search_active?
          when 5, 101
            @editor_state.move_line_end unless editor_search_active?
          when 11, 107
            nano_cut_selection_or_line unless editor_search_active?
          when 15, 111
            save_editor
          when 21, 117
            @editor_state.yank_kill_buffer unless editor_search_active?
          when 22, 118
            @editor_state.page_down(editor_page_rows) unless editor_search_active?
          when 23, 119
            editor_search_active? ? editor_search_append(key) : editor_search_begin
          when 24, 120
            quit_editor("Unsaved changes. Press Ctrl+X again to discard.")
          when 25, 121
            @editor_state.page_up(editor_page_rows) unless editor_search_active?
          when 30, 54
            @editor_state.begin_selection unless editor_search_active?
          else
            return false
          end
        else
          handle_editor_csi_u_key(key)
        end
      end

      def nano_cut_selection_or_line
        if editor_selection_active?
          range = @editor_state.selection_range
          @editor_state.cut_range(range[0], range[1])
          @editor_state.status = "Cut selection"
        else
          range = @editor_state.current_line_range
          @editor_state.cut_range(range[0], range[1])
          @editor_state.status = "Cut line"
        end
        true
      end

      def nano_copy_selection
        return false unless editor_selection_active?

        copy_editor_selection
      end

    end
  end
end
