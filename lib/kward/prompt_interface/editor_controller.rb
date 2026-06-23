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

        @editor_state = EditorState.new(path: full_path, content: File.exist?(full_path) ? File.read(full_path) : "", new_file: !File.exist?(full_path), editor_mode: current_editor_mode)
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

      def current_editor_mode
        return normalize_editor_mode(@editor_mode_source.call) if @editor_mode_source.respond_to?(:call)

        @editor_mode
      rescue StandardError
        @editor_mode
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
        return handle_vi_key(key) if @editor_state&.vi?
        return handle_emacs_key(key) if @editor_state&.emacs?
        return handle_nano_key(key) if @editor_state&.nano?
        return if handle_editor_bracketed_paste_key(key)

        csi_result = handle_editor_csi_u_key(key)
        return csi_result unless csi_result == false

        shift_result = handle_editor_shift_navigation_key(key)
        return shift_result unless shift_result == false

        binding_result = handle_editor_key_binding(key)
        return binding_result unless binding_result == false

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
          clear_editor_selection_before_edit
          @editor_state.insert("\n")
        when "\t"
          clear_editor_selection_before_edit
          @editor_state.insert("  ") unless editor_search_active?
        when "\b", "\x7F"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_delete_character : @editor_state.delete_before_cursor
        when "\x03"
          return editor_search_cancel if editor_search_active?
        when "\e"
          return editor_search_cancel if editor_search_active?
          return @editor_state.clear_selection if @editor_state.selection_active?
        when "\x11"
          quit_editor
        when "\x13"
          save_editor
        when "/"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(key) : editor_search_begin
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

      def handle_editor_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        binding_result = handle_editor_modified_csi_u_key(code, modifier)
        return binding_result unless binding_result == false

        case code
        when 13
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_confirm : @editor_state.insert("\n")
        when 27
          editor_search_active? ? editor_search_cancel : @editor_state.clear_selection
        when 8, 127
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_delete_character : @editor_state.delete_before_cursor
          nil
        when 4
          clear_editor_selection_before_edit unless editor_search_active?
          @editor_state.delete_at_cursor unless editor_search_active?
          nil
        else
          return false unless sequence[:modifiers].to_s.empty? || sequence[:modifiers].to_s == "1"
          return false unless code.between?(32, 126)

          char = code.chr(Encoding::UTF_8)
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(char) : @editor_state.insert(char)
        end
      end

      def handle_editor_shift_navigation_key(key)
        return false if editor_search_active?

        case key
        when "\e[1;2D", "\e[2D"
          editor_extending_selection { @editor_state.move_left }
        when "\e[1;2C", "\e[2C"
          editor_extending_selection { @editor_state.move_right }
        when "\e[1;2A", "\e[2A"
          editor_extending_selection { @editor_state.move_up }
        when "\e[1;2B", "\e[2B"
          editor_extending_selection { @editor_state.move_down }
        else
          false
        end
      end

      def handle_editor_key_binding(key)
        case key
        when "\x01"
          @editor_state.move_line_start unless editor_search_active?
        when "\x02"
          @editor_state.move_left unless editor_search_active?
        when "\x04"
          @editor_state.delete_at_cursor unless editor_search_active?
        when "\x05"
          @editor_state.move_line_end unless editor_search_active?
        when "\x06"
          @editor_state.move_right unless editor_search_active?
        when "\x00"
          @editor_state.begin_selection unless editor_search_active?
        when "\x0B"
          @editor_state.kill_line_after_cursor unless editor_search_active?
        when "\x0E"
          @editor_state.move_down unless editor_search_active?
        when "\x10"
          @editor_state.move_up unless editor_search_active?
        when "\x15"
          @editor_state.kill_line_before_cursor unless editor_search_active?
        when "\x17"
          @editor_state.delete_word_before_cursor unless editor_search_active?
        when "\x19"
          editor_selection_active? ? copy_editor_selection : @editor_state.yank_kill_buffer unless editor_search_active?
        when "\e[D", "\eOD"
          @editor_state.move_left unless editor_search_active?
        when "\e[C", "\eOC"
          @editor_state.move_right unless editor_search_active?
        when "\e[H", "\eOH", "\e[1~", "\e[7~"
          @editor_state.move_line_start unless editor_search_active?
        when "\e[F", "\eOF", "\e[4~", "\e[8~"
          @editor_state.move_line_end unless editor_search_active?
        when "\e[3~"
          @editor_state.delete_at_cursor unless editor_search_active?
        when "\eb", "\eB"
          @editor_state.move_to_previous_word unless editor_search_active?
        when "\ef", "\eF"
          @editor_state.move_to_next_word unless editor_search_active?
        when "\ed", "\eD"
          @editor_state.delete_word_after_cursor unless editor_search_active?
        when "\e\b", "\e\x7F"
          @editor_state.delete_word_before_cursor unless editor_search_active?
        else
          handle_editor_modified_ansi_key(key) || false
        end
      end

      def handle_editor_modified_csi_u_key(code, modifier)
        return false unless ctrl_modifier?(modifier) || alt_modifier?(modifier)

        normalized_code = code.to_i.chr.downcase.ord rescue code
        if ctrl_modifier?(modifier)
          case normalized_code
          when 32
            @editor_state.begin_selection unless editor_search_active?
          when 97
            @editor_state.move_line_start unless editor_search_active?
          when 98
            @editor_state.move_left unless editor_search_active?
          when 99
            editor_search_cancel if editor_search_active?
          when 100
            @editor_state.delete_at_cursor unless editor_search_active?
          when 101
            @editor_state.move_line_end unless editor_search_active?
          when 102
            @editor_state.move_right unless editor_search_active?
          when 107
            @editor_state.kill_line_after_cursor unless editor_search_active?
          when 110
            @editor_state.move_down unless editor_search_active?
          when 112
            @editor_state.move_up unless editor_search_active?
          when 113
            quit_editor
          when 115
            save_editor
          when 117
            @editor_state.kill_line_before_cursor unless editor_search_active?
          when 119
            @editor_state.delete_word_before_cursor unless editor_search_active?
          when 121
            editor_selection_active? ? copy_editor_selection : @editor_state.yank_kill_buffer unless editor_search_active?
          else
            false
          end
        elsif alt_modifier?(modifier)
          case normalized_code
          when 98
            @editor_state.move_to_previous_word unless editor_search_active?
          when 100
            @editor_state.delete_word_after_cursor unless editor_search_active?
          when 102
            @editor_state.move_to_next_word unless editor_search_active?
          else
            false
          end
        else
          false
        end
      end

      def handle_editor_modified_ansi_key(key)
        match = key.to_s.match(/\A\e\[(\d+);(\d+)([CDFH])\z/)
        if match
          modifier = match[2].to_i
          final = match[3]
          return false unless alt_modifier?(modifier)

          case final
          when "C"
            @editor_state.move_to_next_word unless editor_search_active?
          when "D"
            @editor_state.move_to_previous_word unless editor_search_active?
          when "F"
            @editor_state.move_line_end unless editor_search_active?
          when "H"
            @editor_state.move_line_start unless editor_search_active?
          else
            false
          end
        elsif (match = key.to_s.match(/\A\e\[3;(\d+)~\z/))
          if alt_modifier?(match[1].to_i)
            @editor_state.delete_word_after_cursor unless editor_search_active?
          else
            @editor_state.delete_at_cursor unless editor_search_active?
          end
        else
          false
        end
      end

      def handle_editor_bracketed_paste_key(key)
        paste = read_bracketed_paste(key)
        return false unless paste

        @editor_state.insert(normalize_paste(paste[:content])) unless editor_search_active?
        queue_pending_keys(paste[:remaining]) if paste[:remaining] && !paste[:remaining].empty?
        true
      end

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

      def handle_emacs_key(key)
        return if handle_editor_bracketed_paste_key(key)

        csi_result = handle_emacs_csi_u_key(key)
        return csi_result unless csi_result == false

        if @editor_state.emacs_pending == "C-x"
          return handle_emacs_ctrl_x_key(key)
        end

        shift_result = handle_editor_shift_navigation_key(key)
        return shift_result unless shift_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_emacs_key(token)
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
        when "\x00"
          @editor_state.begin_selection unless editor_search_active?
        when "\x01"
          @editor_state.move_line_start unless editor_search_active?
        when "\x02"
          @editor_state.move_left unless editor_search_active?
        when "\x04"
          @editor_state.delete_at_cursor unless editor_search_active?
        when "\x05"
          @editor_state.move_line_end unless editor_search_active?
        when "\x06"
          @editor_state.move_right unless editor_search_active?
        when "\x07"
          emacs_cancel
        when "\x0B"
          if editor_selection_active?
            emacs_kill_selection
          else
            @editor_state.kill_line_after_cursor unless editor_search_active?
          end
        when "\x0E"
          @editor_state.move_down unless editor_search_active?
        when "\x10"
          @editor_state.move_up unless editor_search_active?
        when "\x12"
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:backward)
        when "\x13"
          editor_search_active? ? editor_search_append(key) : editor_search_begin(:forward)
        when "\x15"
          @editor_state.kill_line_before_cursor unless editor_search_active?
        when "\x16"
          @editor_state.page_down(editor_page_rows) unless editor_search_active?
        when "\x17"
          editor_selection_active? ? emacs_kill_selection : @editor_state.delete_word_before_cursor unless editor_search_active?
        when "\x18"
          @editor_state.emacs_pending = "C-x"
          @editor_state.status = "C-x"
        when "\x19"
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

      def handle_emacs_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        normalized_code = ctrl_code(code)

        if ctrl_modifier?(modifier)
          case normalized_code
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
            @editor_state.move_down unless editor_search_active?
          when 112
            @editor_state.move_up unless editor_search_active?
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
        else
          handle_editor_csi_u_key(key)
        end
      end

      def ctrl_code(code)
        value = code.to_i
        return value if value < 32

        value.chr.downcase.ord
      rescue StandardError
        code
      end

      def handle_emacs_ctrl_x_key(key)
        @editor_state.emacs_pending = nil
        case key
        when "\x13"
          save_editor
        when "\x03"
          quit_editor("Unsaved changes. Press C-x C-c again to discard.")
        else
          @editor_state.status = "Unknown C-x command"
          true
        end
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

      def handle_vi_key(key)
        csi_result = handle_vi_csi_u_key(key)
        return csi_result unless csi_result == false

        return handle_vi_search_key(key) if editor_search_active?
        return handle_vi_command_key(key) if @editor_state.vi_mode == "command"
        return handle_vi_insert_key(key) if @editor_state.vi_mode == "insert"
        return handle_vi_visual_key(key) if vi_visual_mode?

        handle_vi_normal_key(key)
      end

      def handle_vi_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        normalized_code = code.to_i.chr.downcase.ord rescue code
        return false unless code == 27 || (ctrl_modifier?(modifier) && normalized_code == 99)

        return editor_search_cancel if editor_search_active?

        @editor_state.vi_command = ""
        @editor_state.vi_pending = ""
        @editor_state.clear_selection
        vi_return_to_normal
      end

      def handle_vi_search_key(key)
        case key
        when "\n", "\r"
          editor_search_confirm
        when "\b", "\x7F"
          editor_search_delete_character
        when "\e", "\x03"
          editor_search_cancel
        else
          editor_search_append(key) if printable_key?(key)
        end
        true
      end

      def handle_vi_insert_key(key)
        return if handle_editor_bracketed_paste_key(key)

        case key
        when "\e", "\x03", :escape
          vi_return_to_normal
        when "\b", "\x7F"
          vi_record_undo { @editor_state.delete_before_cursor }
        when "\n", "\r"
          vi_record_undo { @editor_state.insert("\n") }
        else
          key_name = key_name_for(key)
          named_result = handle_vi_insert_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          vi_record_undo { @editor_state.insert(key) } if printable_key?(key)
        end
      end

      def handle_vi_insert_named_key(key_name)
        case key_name
        when :escape
          vi_return_to_normal
        when :return, :enter
          vi_record_undo { @editor_state.insert("\n") }
        when :backspace
          vi_record_undo { @editor_state.delete_before_cursor }
        when :delete
          vi_record_undo { @editor_state.delete_at_cursor }
        when :left
          @editor_state.move_left
        when :right
          @editor_state.move_right
        when :up
          @editor_state.move_up
        when :down
          @editor_state.move_down
        else
          false
        end
      end

      def handle_vi_command_key(key)
        case key
        when "\e", "\x03", :escape
          @editor_state.vi_command = ""
          vi_return_to_normal
        when "\b", "\x7F"
          @editor_state.vi_command = @editor_state.vi_command[0...-1].to_s
          @editor_state.status = ":#{@editor_state.vi_command}"
        when "\n", "\r"
          execute_vi_command(@editor_state.vi_command)
        else
          if printable_key?(key)
            @editor_state.vi_command = @editor_state.vi_command.to_s + key
            @editor_state.status = ":#{@editor_state.vi_command}"
          end
        end
        true
      end

      def execute_vi_command(command)
        command = command.to_s.strip
        @editor_state.vi_mode = "normal"
        @editor_state.vi_command = ""
        case command
        when "w"
          save_editor
        when "q"
          vi_quit_editor
        when "q!"
          close_editor
        when "wq"
          save_editor && close_editor
        when "x"
          save_editor if @editor_state&.dirty?
          close_editor if @editor_state
        when /\A\d+\z/
          @editor_state.set_cursor_line_and_column(command.to_i - 1, 0)
          @editor_state.status = "Line #{command}"
        else
          @editor_state.status = "Unknown command: #{command}"
        end
        true
      end

      def vi_quit_editor
        return close_editor unless @editor_state.dirty?

        @editor_state.status = "No write since last change (:q! overrides)"
        true
      end

      def handle_vi_normal_key(key)
        key_name = key_name_for(key)
        return handle_vi_named_key(key_name) if key_name
        return false unless key.is_a?(String)

        if key == "\e" || key == "\x03"
          @editor_state.vi_pending = ""
          vi_return_to_normal
          return true
        end
        return true unless printable_key?(key)

        pending = @editor_state.vi_pending.to_s + key
        if vi_waiting_for_more?(pending)
          @editor_state.vi_pending = pending
          @editor_state.status = "NORMAL #{pending}"
          return true
        end

        @editor_state.vi_pending = ""
        execute_vi_normal_command(pending)
        true
      end

      def handle_vi_named_key(key_name)
        case key_name
        when :escape
          @editor_state.vi_pending = ""
          vi_return_to_normal
        when :left
          @editor_state.move_left
        when :right
          @editor_state.move_right
        when :up
          @editor_state.move_up
        when :down
          @editor_state.move_down
        else
          false
        end
      end

      def vi_visual_mode?
        %w[visual visual_line].include?(@editor_state.vi_mode)
      end

      def vi_return_to_normal
        @editor_state.vi_mode = "normal"
        @editor_state.status = "NORMAL · i insert · :w save · :q quit"
        true
      end

      def vi_cancel_visual_mode
        @editor_state.vi_pending = ""
        @editor_state.clear_selection
        vi_return_to_normal
      end

      def vi_waiting_for_more?(command)
        return true if command.match?(/\A\d+\z/) && command != "0"
        return true if command.match?(/\A\d*g\z/)
        return true if command.match?(/\A\d*[dy]\d*\z/)

        false
      end

      def execute_vi_normal_command(command)
        count, body = vi_count_and_body(command)
        count = 1 if count.zero?
        case body
        when "h"
          count.times { @editor_state.move_left }
        when "j"
          count.times { @editor_state.move_down }
        when "k"
          count.times { @editor_state.move_up }
        when "l"
          count.times { @editor_state.move_right }
        when "0"
          @editor_state.move_line_start
        when "$"
          @editor_state.move_line_end
        when "w"
          count.times { @editor_state.move_to_next_word }
        when "b"
          count.times { @editor_state.move_to_previous_word }
        when "gg"
          @editor_state.move_file_start
        when "G"
          line = command.match?(/\A\d+G\z/) ? count - 1 : @editor_state.lines.length - 1
          @editor_state.set_cursor_line_and_column(line, 0)
        when "i"
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "I"
          @editor_state.move_line_start
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "a"
          @editor_state.move_right
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "A"
          @editor_state.move_line_end
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "v"
          vi_begin_visual_mode("visual")
        when "V"
          vi_begin_visual_mode("visual_line")
        when "o"
          vi_open_line_below
        when "O"
          vi_open_line_above
        when "x"
          vi_record_undo { count.times { @editor_state.delete_at_cursor } }
        when "dd"
          vi_delete_lines(count)
        when "yy"
          vi_yank_lines(count)
        when "p"
          vi_record_undo { @editor_state.insert(@editor_state.kill_buffer) }
        when "u"
          @editor_state.undo
        when ":"
          @editor_state.vi_mode = "command"
          @editor_state.vi_command = ""
          @editor_state.status = ":"
        when "/"
          editor_search_begin
        else
          if body.start_with?("d") || body.start_with?("y")
            vi_operator_motion(body[0], body[1..], count)
          else
            @editor_state.status = "Unknown command: #{command}"
          end
        end
      end

      def handle_vi_visual_key(key)
        key_name = key_name_for(key)
        return handle_vi_visual_named_key(key_name) if key_name
        if key == "\e" || key == "\x03"
          vi_cancel_visual_mode
          return true
        end
        return true unless printable_key?(key)

        case key
        when "y"
          vi_yank_visual_selection
        when "d", "x"
          vi_delete_visual_selection
        when "c"
          vi_change_visual_selection
        when "p"
          vi_paste_visual_selection
        else
          vi_move_visual_selection(key)
        end
        true
      end

      def handle_vi_visual_named_key(key_name)
        case key_name
        when :escape
          vi_cancel_visual_mode
        when :left
          @editor_state.move_left
        when :right
          @editor_state.move_right
        when :up
          @editor_state.move_up
        when :down
          @editor_state.move_down
        else
          false
        end
      end

      def vi_begin_visual_mode(mode)
        @editor_state.clear_selection
        @editor_state.selection_anchor = @editor_state.cursor
        @editor_state.vi_mode = mode
        @editor_state.status = mode == "visual_line" ? "VISUAL LINE" : "VISUAL"
        true
      end

      def vi_move_visual_selection(key)
        count, body = vi_count_and_body(key)
        count = 1 if count.zero?
        vi_apply_motion(body, count)
      end

      def vi_visual_range
        @editor_state.selection_range
      end

      def vi_yank_visual_selection
        range = vi_visual_range
        return false unless range

        vi_copy_range(range[0], range[1], "Yanked selection")
        vi_cancel_visual_mode
      end

      def vi_delete_visual_selection
        range = vi_visual_range
        return false unless range

        @editor_state.copy_range(range[0], range[1])
        vi_record_undo { @editor_state.replace_range(range[0], range[1], "") }
        vi_cancel_visual_mode
      end

      def vi_change_visual_selection
        range = vi_visual_range
        return false unless range

        @editor_state.copy_range(range[0], range[1])
        vi_record_undo { @editor_state.replace_range(range[0], range[1], "") }
        @editor_state.clear_selection
        @editor_state.vi_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vi_paste_visual_selection
        range = vi_visual_range
        return false unless range

        text = @editor_state.kill_buffer.to_s
        vi_record_undo { @editor_state.replace_range(range[0], range[1], text) }
        vi_cancel_visual_mode
      end

      def vi_count_and_body(command)
        match = command.match(/\A(\d*)(.*)\z/)
        [match[1].to_i, match[2]]
      end

      def vi_open_line_below
        line, = @editor_state.cursor_line_and_column
        line_end = @editor_state.line_start_offset(line) + @editor_state.lines[line].to_s.length
        vi_record_undo do
          @editor_state.cursor = line_end
          @editor_state.insert("\n")
        end
        @editor_state.vi_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vi_open_line_above
        line, = @editor_state.cursor_line_and_column
        start_index = @editor_state.line_start_offset(line)
        vi_record_undo do
          @editor_state.cursor = start_index
          @editor_state.insert("\n")
          @editor_state.cursor = start_index
        end
        @editor_state.vi_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vi_delete_lines(count)
        line, = @editor_state.cursor_line_and_column
        start_index, = @editor_state.line_range(line)
        end_line = [line + count - 1, @editor_state.lines.length - 1].min
        _, end_index = @editor_state.line_range(end_line)
        @editor_state.copy_range(start_index, end_index)
        vi_record_undo { @editor_state.replace_range(start_index, end_index, "") }
        @editor_state.status = "Deleted #{count} line#{count == 1 ? "" : "s"}"
      end

      def vi_yank_lines(count)
        line, = @editor_state.cursor_line_and_column
        start_index, = @editor_state.line_range(line)
        end_line = [line + count - 1, @editor_state.lines.length - 1].min
        _, end_index = @editor_state.line_range(end_line)
        vi_copy_range(start_index, end_index, "Yanked #{count} line#{count == 1 ? "" : "s"}")
      end

      def vi_operator_motion(operator, motion, count)
        motion_count, motion = vi_count_and_body(motion)
        count = motion_count if motion_count.positive?
        start_index = @editor_state.cursor
        vi_apply_motion(motion, count)
        end_index = @editor_state.cursor
        if motion == "$"
          end_index = [end_index + 1, @editor_state.buffer.length].min
        end
        return @editor_state.status = "Empty range" if start_index == end_index

        if operator == "d"
          @editor_state.copy_range(start_index, end_index)
          vi_record_undo { @editor_state.replace_range(start_index, end_index, "") }
          @editor_state.status = "Deleted"
        else
          vi_copy_range(start_index, end_index, "Yanked")
          @editor_state.cursor = start_index
        end
      end

      def vi_apply_motion(motion, count)
        case motion
        when "w"
          count.times { @editor_state.move_to_next_word }
        when "b"
          count.times { @editor_state.move_to_previous_word }
        when "$"
          @editor_state.move_line_end
        when "0"
          @editor_state.move_line_start
        when "h"
          count.times { @editor_state.move_left }
        when "j"
          count.times { @editor_state.move_down }
        when "k"
          count.times { @editor_state.move_up }
        when "l"
          count.times { @editor_state.move_right }
        else
          @editor_state.status = "Unsupported motion: #{motion}"
        end
      end

      def vi_copy_range(start_index, end_index, status)
        @editor_state.copy_range(start_index, end_index)
        @output_io.print("\e]52;c;#{Base64.strict_encode64(@editor_state.kill_buffer)}\a")
        @output_io.flush if @output_io.respond_to?(:flush)
        @editor_state.status = status
      end

      def vi_record_undo
        before = @editor_state.buffer.dup
        @editor_state.push_undo
        yield
        @editor_state.undo_stack.pop if @editor_state.buffer == before
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
        @output_io.print("\e]52;c;#{Base64.strict_encode64(@editor_state.kill_buffer)}\a")
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

      def editor_extending_selection
        @editor_state.selection_anchor ||= @editor_state.cursor
        yield
        true
      end

      def editor_selection_active?
        @editor_state&.selection_active?
      end

      def clear_editor_selection_before_edit
        @editor_state&.clear_selection
      end

      def copy_editor_selection
        text = @editor_state.selected_text
        return false if text.empty?

        @output_io.print("\e]52;c;#{Base64.strict_encode64(text)}\a")
        @output_io.flush if @output_io.respond_to?(:flush)
        @editor_state.clear_selection
        @editor_state.status = "Copied selection"
        true
      end

      def editor_search_active?
        @editor_state&.search_active
      end

      def editor_search_begin(direction = :forward)
        @editor_state.begin_search(direction)
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

      def quit_editor(message = "Unsaved changes. Press Ctrl+Q again to discard.")
        return false unless @editor_state
        return close_editor unless @editor_state.dirty?
        return close_editor if @editor_state.quit_confirmed

        @editor_state.quit_confirmed = true
        @editor_state.status = message
        true
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
