# Namespace for the Kward CLI agent runtime.
module Kward
  # Keyboard sequence dispatcher for composer and overlay input.
  class PromptInterface
    # Keyboard sequence handling for the terminal prompt interface.
    module KeyHandler
      private

      def read_key(nonblock: false)
        pending = @pending_keys.shift unless @pending_keys.empty?
        return pending if pending

        return nil if nonblock && @input_io.respond_to?(:wait_readable) && !@input_io.wait_readable(0)

        @reader.read_keypress(echo: false, raw: true, nonblock: nonblock)
      rescue TTY::Reader::InputInterrupt
        "\x03"
      rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
        nil
      end

      def handle_editor_input_key(key)
        result = handle_editor_key(key)
        result.is_a?(String) ? true : result
      end

      def handle_key(key)
        return submit_input if key.nil?
        return handle_interactive_key(key) if interactive_active_locked?
        return handle_editor_input_key(key) if editor_active?
        return if handle_bracketed_paste_key(key)

        csi_result = handle_csi_u_key(key)
        return csi_result unless csi_result == false
        return if handle_shift_enter_key(key)
        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_key(token)
          end
        end

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        binding_result = handle_composer_key_binding(key)
        return binding_result unless binding_result == false

        case key_name_for(key)
        when :return, :enter
          file_open_overlay_visible? ? open_selected_file_in_editor(fallback_to_typed_path: true) : submit_input
        when :backspace
          delete_before_cursor
        when :delete
          delete_at_cursor
        when :ctrl_d
          delete_at_cursor_or_exit
        when :ctrl_c
          cancel_input_or_interrupt
        when :ctrl_a
          move_to_start_of_line
        when :ctrl_e
          move_to_end_of_line
        when :ctrl_b
          move_cursor_left
        when :ctrl_f
          move_cursor_right
        when :ctrl_w
          delete_word_before_cursor
        when :ctrl_u
          kill_line_before_cursor
        when :ctrl_k
          kill_line_after_cursor
        when :ctrl_y
          yank_kill_buffer
        when :ctrl_l
          redraw_screen_locked
        when :left
          move_cursor_left
        when :right
          move_cursor_right
        when :home
          move_to_start_of_line
        when :end
          move_to_end_of_line
        when :up
          if file_overlay_visible?
            select_previous_file_mention
          elsif slash_overlay_visible?
            select_previous_slash_command
          else
            recall_previous_history
          end
        when :down
          if file_overlay_visible?
            select_next_file_mention
          elsif slash_overlay_visible?
            select_next_slash_command
          else
            recall_next_history
          end
        else
          case key
          when "\n", "\r"
            file_open_overlay_visible? ? open_selected_file_in_editor(fallback_to_typed_path: true) : submit_input
          when "\t"
            open_selected_file_in_editor || complete_selected_file_mention || complete_selected_slash_command || insert_key(key)
          when "\b", "\x7F"
            delete_before_cursor
          when "\x04"
            delete_at_cursor_or_exit
          when "\x03"
            cancel_input_or_interrupt
          when "\e"
            handle_escape_sequence
          else
            insert_key(key)
          end
        end
      end

      def cancel_input_or_interrupt
        return CANCEL_INPUT if @busy

        raise Interrupt
      end

      def handle_escape_sequence
        pending_sequence = read_pending_escape_sequence
        return true if pending_sequence.empty? && (dismiss_file_overlay || dismiss_slash_overlay)

        full_sequence = "\e#{pending_sequence}"
        sequence = next_key_token(full_sequence)
        queue_pending_keys(full_sequence[sequence.length..]) if full_sequence.length > sequence.length
        return true if sequence == "\e" && (dismiss_file_overlay || dismiss_slash_overlay)
        return true if handle_shift_enter_key(sequence)

        tab_result = handle_tab_key_binding(sequence)
        return tab_result unless tab_result == false

        binding_result = handle_composer_key_binding(sequence)
        return binding_result unless binding_result == false

        case key_name_for(sequence)
        when :up
          if file_overlay_visible?
            select_previous_file_mention
          elsif slash_overlay_visible?
            select_previous_slash_command
          else
            recall_previous_history
          end
        when :down
          if file_overlay_visible?
            select_next_file_mention
          elsif slash_overlay_visible?
            select_next_slash_command
          else
            recall_next_history
          end
        when :left
          move_cursor_left
        when :right
          move_cursor_right
        when :home
          move_to_start_of_line
        when :end
          move_to_end_of_line
        when :delete
          delete_at_cursor
        end
        true
      end

      def handle_bracketed_paste_key(key)
        paste = read_bracketed_paste(key)
        return false unless paste

        insert_paste(normalize_paste(paste[:content]))
        queue_pending_keys(paste[:remaining]) if paste[:remaining] && !paste[:remaining].empty?
        true
      end

      def read_bracketed_paste(key)
        text = key.to_s
        return nil unless text.start_with?(BRACKETED_PASTE_START)

        pasted = text[BRACKETED_PASTE_START.length..] || ""
        until pasted.include?(BRACKETED_PASTE_END)
          chunk = @reader.read_keypress(echo: false, raw: true)
          break if chunk.nil?

          pasted << chunk.to_s
        end

        content, remaining = pasted.split(BRACKETED_PASTE_END, 2)
        { content: content || "", remaining: remaining }
      end

      def normalize_paste(content)
        content.gsub("\r\n", "\n").gsub("\r", "\n")
      end

      def handle_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        case code
        when 9
          if ctrl_modifier?(modifier)
            shift_modifier?(modifier) ? { tab_action: :previous } : { tab_action: :next }
          else
            insert_csi_u_text(sequence) || false
          end
        when 13
          if modifier == 2
            insert_string("\n")
          elsif file_open_overlay_visible?
            open_selected_file_in_editor(fallback_to_typed_path: true)
          else
            submit_input
          end
        when 27
          dismiss_file_overlay || dismiss_slash_overlay || false
        when 8, 127
          alt_modifier?(modifier) ? delete_word_before_cursor : delete_before_cursor
          nil
        when 4
          delete_at_cursor_or_exit
        else
          handle_modified_csi_u_key(code, modifier) || insert_csi_u_text(sequence)
        end
      end

      def parse_csi_u_key(key)
        match = key.to_s.match(/\A\e\[(\d+)((?:;[\d:]*)*)u/)
        return nil unless match

        fields = match[2].to_s.split(";", -1)[1..] || []
        modifiers = fields[0].to_s
        modifier = (modifiers.empty? ? "1" : modifiers).split(":", 2).first.to_i
        {
          sequence: match[0],
          code: match[1].to_i,
          modifiers: modifiers,
          modifier: modifier,
          text: fields[1].to_s,
          remaining: key.to_s[match[0].length..]
        }
      end

      def insert_csi_u_text(sequence)
        text = sequence[:text].to_s
        return false if text.empty?

        insert_string(text.split(":").map { |codepoint| codepoint.to_i.chr(Encoding::UTF_8) }.join)
      end

      def handle_modified_csi_u_key(code, modifier)
        return false unless ctrl_modifier?(modifier) || alt_modifier?(modifier)

        normalized_code = code.to_i.chr.downcase.ord rescue code
        if ctrl_modifier?(modifier)
          case normalized_code
          when 97
            move_to_start_of_line
          when 98
            move_cursor_left
          when 99
            cancel_input_or_interrupt
          when 100
            delete_at_cursor_or_exit
          when 101
            move_to_end_of_line
          when 102
            move_cursor_right
          when 104
            delete_before_cursor
          when 107
            kill_line_after_cursor
          when 108
            redraw_screen_locked
          when 117
            kill_line_before_cursor
          when 119
            delete_word_before_cursor
          when 121
            yank_kill_buffer
          else
            false
          end
        elsif alt_modifier?(modifier)
          case normalized_code
          when 98
            move_to_previous_word
          when 100
            delete_word_after_cursor
          when 102
            move_to_next_word
          else
            false
          end
        else
          false
        end
      end

      def key_name_for(key)
        cursor_key_name(key) || @reader.console.keys[key]
      end

      def cursor_key_name(key)
        text = key.to_s
        case text
        when /\A\e\[[0-9;:]*A\z/, "\eOA"
          :up
        when /\A\e\[[0-9;:]*B\z/, "\eOB"
          :down
        when /\A\e\[[0-9;:]*C\z/, "\eOC"
          :right
        when /\A\e\[[0-9;:]*D\z/, "\eOD"
          :left
        when "\e[5~"
          :pageup
        when "\e[6~"
          :pagedown
        end
      end

      def ctrl_modifier?(modifier)
        ((modifier.to_i - 1) & 4).positive?
      end

      def alt_modifier?(modifier)
        ((modifier.to_i - 1) & 2).positive?
      end

      def shift_modifier?(modifier)
        ((modifier.to_i - 1) & 1).positive?
      end

      def handle_shift_enter_key(key)
        sequence = shift_enter_sequence_for(key)
        return false unless sequence

        insert_string("\n")
        queue_pending_keys(key[sequence.length..]) if key.length > sequence.length
        true
      end

      def queue_pending_keys(keys)
        remaining = keys.to_s
        until remaining.empty?
          token = next_key_token(remaining)
          @pending_keys << token
          remaining = remaining[token.length..] || ""
        end
      end

      def next_key_token(keys)
        text = keys.to_s
        text.match(/\A\e\[[0-9;:]*[A-Za-z~]/)&.[](0) ||
          text.match(/\A\eO[A-Za-z]/)&.[](0) ||
          shift_enter_sequence_for(text) ||
          (text.start_with?("\e") && text.length > 1 && alt_key_sequence?(text[1]) ? text[0, 2] : text[0, 1])
      end

      def alt_key_sequence?(char)
        char = char.to_s
        char.match?(/[[:alnum:]]/) || char == "\b" || char == "\x7F"
      end

      def shift_enter_sequence_for(key)
        return nil unless key.is_a?(String)

        SHIFT_ENTER_SEQUENCES.find { |sequence| key.start_with?(sequence) }
      end

      def read_pending_escape_sequence
        sequence = +""
        until @pending_keys.empty?
          sequence << @pending_keys.shift.to_s
        end
        while (char = @reader.read_keypress(echo: false, raw: true, nonblock: true))
          sequence << char.to_s
        end
        sequence
      rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
        sequence
      end

      CTRL_TAB_SEQUENCES = ["\e[9;5u", "\e[27;5;9~", "\e[1;5I"].freeze
      CTRL_SHIFT_TAB_SEQUENCES = ["\e[9;6u", "\e[27;6;9~", "\e[1;6I", "\e[1;6Z"].freeze

      def handle_tab_key_binding(key)
        return false if @select_state || @question_state || @tabs.empty?

        navigation_result = handle_ctrl_tab_navigation_key_binding(key)
        return navigation_result unless navigation_result == false

        @tab_keybindings == "ctrl" ? handle_ctrl_tab_key_binding(key) : handle_alt_tab_key_binding(key)
      end

      def handle_ctrl_tab_navigation_key_binding(key)
        case key
        when *CTRL_TAB_SEQUENCES
          { tab_action: :next }
        when *CTRL_SHIFT_TAB_SEQUENCES
          { tab_action: :previous }
        else
          false
        end
      end

      def handle_ctrl_tab_key_binding(key)
        case key
        when "\x14", "\e[116;5u"
          { tab_action: :new }
        when "\e[119;5u"
          { tab_action: :close }
        else
          ctrl_number_tab_action(key)
        end
      end

      def ctrl_number_tab_action(key)
        match = key.to_s.match(/\A\e\[((?:49)|(?:5[0-7]));5u\z/)
        return false unless match

        { tab_action: :select, index: match[1].to_i - 49 }
      end

      def handle_alt_tab_key_binding(key)
        case key
        when "\et", "\eT"
          { tab_action: :new }
        when "\e[1;3C", "\e[3C"
          { tab_action: :next }
        when "\e[1;3D", "\e[3D"
          { tab_action: :previous }
        else
          alt_number_tab_action(key)
        end
      end

      def alt_number_tab_action(key)
        match = key.to_s.match(/\A\e([1-9])\z/)
        return false unless match

        { tab_action: :select, index: match[1].to_i - 1 }
      end

      def handle_composer_key_binding(key)
        case key
        when "\x01"
          move_to_start_of_line
        when "\x02"
          move_cursor_left
        when "\x04"
          delete_at_cursor_or_exit
        when "\x05"
          move_to_end_of_line
        when "\x06"
          move_cursor_right
        when "\x0B"
          kill_line_after_cursor
        when "\x0C"
          redraw_screen_locked
        when "\x15"
          kill_line_before_cursor
        when "\x17"
          delete_word_before_cursor
        when "\x19"
          yank_kill_buffer
        when "\e[D", "\eOD"
          move_cursor_left
        when "\e[C", "\eOC"
          move_cursor_right
        when "\e[H", "\eOH", "\e[1~", "\e[7~"
          move_to_start_of_line
        when "\e[F", "\eOF", "\e[4~", "\e[8~"
          move_to_end_of_line
        when "\e[3~"
          delete_at_cursor
        when "\eb", "\eB"
          move_to_previous_word
        when "\ef", "\eF"
          move_to_next_word
        when "\ed", "\eD"
          delete_word_after_cursor
        when "\e\b", "\e\x7F"
          delete_word_before_cursor
        else
          handle_modified_ansi_key(key) || false
        end
      end

      def handle_modified_ansi_key(key)
        match = key.to_s.match(/\A\e\[(\d+);(\d+)([CDFH])\z/)
        if match
          modifier = match[2].to_i
          final = match[3]
          return false unless alt_modifier?(modifier)

          case final
          when "C"
            move_to_next_word
          when "D"
            move_to_previous_word
          when "F"
            move_to_end_of_line
          when "H"
            move_to_start_of_line
          else
            false
          end
        elsif (match = key.to_s.match(/\A\e\[3;(\d+)~\z/))
          alt_modifier?(match[1].to_i) ? delete_word_after_cursor : delete_at_cursor
        else
          false
        end
      end

    end
  end
end
