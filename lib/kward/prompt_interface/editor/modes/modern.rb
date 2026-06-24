# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Modern keymap for the built-in composer file editor.
    module ModernEditorMode
      private

      def handle_modern_key(key)
        return if handle_editor_bracketed_paste_key(key)

        csi_result = handle_modern_csi_u_key(key)
        return csi_result unless csi_result == false

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
          clear_editor_selection_before_edit
          @editor_state.insert("\n")
        when "\t"
          clear_editor_selection_before_edit
          @editor_state.insert("  ") unless editor_search_active?
        when "\b", "\x7F"
          editor_search_active? ? editor_search_delete_character : delete_editor_selection || @editor_state.delete_before_cursor
        when "\x03"
          return editor_search_cancel if editor_search_active?
        when "\e"
          return editor_search_cancel if editor_search_active?
          return @editor_state.clear_selection if @editor_state.selection_active?
        when "\x11"
          quit_editor
        when "\x13"
          save_editor
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

      def handle_modern_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        if ctrl_modifier?(modifier)
          handle_modern_ctrl_key(ctrl_code(code), key)
        else
          handle_editor_csi_u_key(key)
        end
      end

      def handle_modern_key_binding(key)
        case key
        when "\x00"
          true
        when "\x03"
          editor_search_active? ? editor_search_cancel : copy_editor_selection
        when "\x06"
          editor_search_active? ? editor_search_append(key) : editor_search_begin
        when "\x16"
          @editor_state.yank_kill_buffer unless editor_search_active?
        when "\x18"
          cut_editor_selection unless editor_search_active?
        else
          handle_editor_key_binding(key)
        end
      end

      def handle_modern_ctrl_key(code, key)
        case code
        when 99
          editor_search_active? ? editor_search_cancel : copy_editor_selection
        when 102
          editor_search_active? ? editor_search_append(key) : editor_search_begin
        when 118
          @editor_state.yank_kill_buffer unless editor_search_active?
        when 120
          cut_editor_selection unless editor_search_active?
        else
          return false if code == 32

          handle_editor_csi_u_key(key)
        end
      end
    end
  end
end
