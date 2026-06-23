# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Built-in composer file editor behavior.
    module EditorController
      private

      def editor_active?
        !@editor_state.nil?
      end

      def open_selected_file_in_editor(fallback_to_typed_path: false)
        path = selected_file_open_path
        return open_editor(path) if path
        return false unless fallback_to_typed_path

        open_typed_file_path_in_editor
      end

      def open_typed_file_path_in_editor
        file_open = active_file_open
        return false unless file_open
        if file_open[:query].empty?
          @file_editor_open_status = "Type a file path after $"
          return false
        end

        open_editor(file_open[:query], allow_new: true)
      end

      def open_editor(path, allow_new: false)
        full_path = File.expand_path(path.to_s, Dir.pwd)
        root = File.expand_path(Dir.pwd)
        unless full_path == root || full_path.start_with?("#{root}/")
          @file_editor_open_status = "Cannot edit file outside workspace"
          return false
        end
        if File.exist?(full_path) && !File.file?(full_path)
          @file_editor_open_status = "Cannot edit non-file path: #{path}"
          return false
        end
        unless File.exist?(full_path)
          unless allow_new
            @file_editor_open_status = "Cannot edit missing file: #{path}"
            return false
          end
          parent = File.dirname(full_path)
          unless Dir.exist?(parent)
            @file_editor_open_status = "Cannot create file; parent directory is missing"
            return false
          end
        end

        @editor_state = EditorState.new(path: full_path, content: File.exist?(full_path) ? File.read(full_path) : "", new_file: !File.exist?(full_path))
        @prompt_label = "Edit>"
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        @pending_keys.clear
        @file_overlay_dismissed_token = nil
        @file_open_dismissed_token = nil
        @asking = true
        true
      rescue StandardError => e
        @file_editor_open_status = "Cannot edit #{path}: #{e.message}"
        false
      end

      def close_editor
        @editor_state = nil
        @prompt_label = "You>"
        self.composer_input = ""
        self.composer_cursor = 0
        @asking = true
      end

      def handle_editor_key(key)
        return if key.nil?
        return if handle_editor_bracketed_paste_key(key)

        csi_result = handle_editor_csi_u_key(key)
        return csi_result unless csi_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_editor_key(token)
          end
        end

        case key
        when "\n", "\r"
          return editor_search_confirm if editor_search_active?
          @editor_state.insert("\n")
        when "\t"
          @editor_state.insert("  ") unless editor_search_active?
        when "\b", "\x7F"
          editor_search_active? ? editor_search_delete_character : @editor_state.delete_before_cursor
        when "\x03", "\e"
          return editor_search_cancel if editor_search_active?
          close_editor
        when "\x13"
          save_editor
        when "/"
          editor_search_active? ? editor_search_append(key) : editor_search_begin
        else
          key_name = key_name_for(key)
          named_result = handle_editor_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          if editor_search_active?
            editor_search_append(key) if printable_key?(key)
          else
            @editor_state.insert(key) if printable_key?(key)
          end
        end
      end

      def handle_editor_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        if ctrl_modifier?(modifier)
          char = begin
            code.to_i.chr.downcase
          rescue RangeError
            nil
          end
          case char
          when "c"
            return editor_search_active? ? editor_search_cancel : close_editor
          when "s"
            return save_editor
          end
        end

        case code
        when 13
          editor_search_active? ? editor_search_confirm : @editor_state.insert("\n")
        when 27
          editor_search_active? ? editor_search_cancel : close_editor
        when 8, 127
          editor_search_active? ? editor_search_delete_character : @editor_state.delete_before_cursor
          nil
        when 4
          @editor_state.delete_at_cursor unless editor_search_active?
          nil
        else
          return false unless sequence[:modifiers].to_s.empty? || sequence[:modifiers].to_s == "1"
          return false unless code.between?(32, 126)

          char = code.chr(Encoding::UTF_8)
          editor_search_active? ? editor_search_append(char) : @editor_state.insert(char)
        end
      end

      def handle_editor_bracketed_paste_key(key)
        paste = read_bracketed_paste(key)
        return false unless paste

        @editor_state.insert(normalize_paste(paste[:content])) unless editor_search_active?
        queue_pending_keys(paste[:remaining]) if paste[:remaining] && !paste[:remaining].empty?
        true
      end

      def handle_editor_named_key(key_name)
        return false unless key_name

        if editor_search_active?
          case key_name
          when :return, :enter
            editor_search_confirm
          when :backspace
            editor_search_delete_character
          else
            false
          end
        else
          case key_name
          when :return, :enter
            @editor_state.insert("\n")
          when :backspace
            @editor_state.delete_before_cursor
          when :delete
            @editor_state.delete_at_cursor
          when :left
            @editor_state.move_left
          when :right
            @editor_state.move_right
          when :up
            @editor_state.move_up
          when :down
            @editor_state.move_down
          when :home
            @editor_state.move_line_start
          when :end
            @editor_state.move_line_end
          when :pageup
            @editor_state.page_up(editor_page_rows)
          when :pagedown
            @editor_state.page_down(editor_page_rows)
          else
            false
          end
        end
      end

      def editor_search_active?
        @editor_state&.search_active
      end

      def editor_search_begin
        @editor_state.begin_search
        true
      end

      def editor_search_append(text)
        @editor_state.append_search(text)
        true
      end

      def editor_search_delete_character
        @editor_state.delete_search_character
        true
      end

      def editor_search_confirm
        @editor_state.confirm_search
        true
      end

      def editor_search_cancel
        @editor_state.cancel_search
        true
      end

      def editor_page_rows
        [[screen_height - 6, 1].max, 10].min
      end

      def save_editor
        return false unless @editor_state

        if @editor_state.file_changed_on_disk? && !@editor_state.overwrite_confirmed
          @editor_state.overwrite_confirmed = true
          @editor_state.status = "File changed on disk. Press Ctrl+S again to overwrite."
          return true
        end

        File.write(@editor_state.path, @editor_state.buffer)
        @editor_state.refresh_after_save(@editor_state.buffer)
        true
      rescue StandardError => e
        @editor_state.status = "Save failed: #{e.message}" if @editor_state
        false
      end

      def printable_key?(key)
        key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)
      end
    end
  end
end
