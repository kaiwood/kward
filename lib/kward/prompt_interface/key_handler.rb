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
        TerminalKeys::CTRL_C
      rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
        nil
      end

      def handle_editor_input_key(key)
        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        result = handle_editor_key(key)
        result.is_a?(String) ? true : result
      end

      def handle_key(key)
        return submit_input if key.nil?
        return handle_interactive_key(key) if interactive_active_locked?
        return handle_editor_input_key(key) if editor_active?
        return handle_project_browser_key(key) if project_browser_visible?
        return handle_history_search_key(key) if history_search_active?
        return true if handle_mouse_reporting_key(key)
        return if handle_bracketed_paste_key(key)

        csi_result = handle_csi_u_key(key)
        return csi_result unless csi_result == false
        return if handle_shift_enter_key(key)
        return true if handle_bundled_key(key) { |token| handle_key(token) }

        completion_result = handle_completion_provider_key(key)
        return completion_result unless completion_result == false

        reasoning_result = handle_reasoning_key_binding(key)
        return reasoning_result unless reasoning_result == false

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
        when :ctrl_r
          start_history_search
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
            handle_tab_completion_key
          when "\b", "\x7F"
            delete_before_cursor
          when TerminalKeys::CTRL_D
            delete_at_cursor_or_exit
          when TerminalKeys::CTRL_C
            cancel_input_or_interrupt
          when TerminalKeys::CTRL_R
            start_history_search
          when "\e"
            handle_escape_sequence
          else
            insert_key(key)
          end
        end
      end

      def handle_history_search_key(key)
        csi_result = handle_history_search_csi_u_key(key)
        return csi_result unless csi_result == false
        return true if handle_bundled_key(key) { |token| handle_history_search_key(token) }

        case key_name_for(key)
        when :return, :enter
          accept_history_search
        when :up
          select_previous_history_search_match
        when :down
          select_next_history_search_match
        when :backspace
          update_history_search_query(composer_input[0...-1].to_s)
        when :ctrl_c
          cancel_history_search
        else
          case key
          when "\n", "\r"
            accept_history_search
          when "\b", "\x7F"
            update_history_search_query(composer_input[0...-1].to_s)
          when TerminalKeys::CTRL_C, "\e"
            cancel_history_search
          else
            append_history_search_key(key)
          end
        end
        true
      end

      def handle_history_search_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        if ctrl_modifier?(modifier) && ctrl_code_for(code) == 99
          cancel_history_search
        elsif code == 13
          accept_history_search
        elsif code == 27
          cancel_history_search
        elsif code == 8 || code == 127
          update_history_search_query(composer_input[0...-1].to_s)
        else
          text = csi_u_printable_text(sequence)
          update_history_search_query(composer_input + text) if text
        end
        true
      end

      def append_history_search_key(key)
        return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

        update_history_search_query(composer_input + key)
      end

      def cancel_input_or_interrupt
        return CANCEL_INPUT if @busy

        true
      end

      def handle_tab_completion_key
        open_selected_file_in_editor || complete_selected_file_mention || complete_selected_slash_command || insert_key("\t")
      end

      def handle_escape_sequence
        pending_sequence = read_pending_escape_sequence
        return true if pending_sequence.empty? && (dismiss_file_overlay || dismiss_slash_overlay)

        full_sequence = "\e#{pending_sequence}"
        return true if handle_mouse_reporting_key(full_sequence)

        sequence = next_key_token(full_sequence)
        queue_pending_keys(full_sequence[sequence.length..]) if full_sequence.length > sequence.length
        return true if sequence == "\e" && (dismiss_file_overlay || dismiss_slash_overlay)
        return true if handle_shift_enter_key(sequence)

        reasoning_result = handle_reasoning_key_binding(sequence)
        return reasoning_result unless reasoning_result == false

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
        handle_bracketed_paste(key) { |content| insert_paste(content) }
      end

      def handle_mouse_reporting_key(key)
        event = parse_sgr_mouse_event(key)
        return false unless event

        queue_pending_keys(event[:remaining]) unless event[:remaining].empty?
        true
      end

      def handle_bracketed_paste(key)
        paste = read_bracketed_paste(key)
        return false unless paste

        yield normalize_paste(paste[:content])
        queue_pending_keys(paste[:remaining]) if paste[:remaining] && !paste[:remaining].empty?
        true
      end

      def parse_sgr_mouse_event(key)
        match = key.to_s.match(/\A(?:\e)?\[<(\d+);(\d+);(\d+)([Mm])/)
        return nil unless match

        code = match[1].to_i
        {
          code: code,
          button: code & 3,
          column: match[2].to_i,
          row: match[3].to_i,
          action: match[4],
          release: match[4] == "m",
          drag: (code & 32).positive?,
          remaining: key.to_s[match[0].length..].to_s
        }
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
          elsif shift_modifier?(modifier)
            handle_reasoning_key_binding(key) || handle_tab_completion_key
          else
            completion_result = handle_completion_provider_key("\t")
            completion_result == false ? handle_reasoning_key_binding("\t") || handle_tab_completion_key : completion_result
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
        match = key.to_s.match(TerminalKeys::CSI_U_PATTERN)
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
        text = csi_u_printable_text(sequence)
        return true if text.nil? && csi_u_text_field?(sequence)
        return false unless text

        insert_string(text)
      end

      def csi_u_text_field?(sequence)
        !sequence[:text].to_s.empty?
      end

      def csi_u_printable_text(sequence)
        text = csi_u_text(sequence)
        return text unless text.empty?
        return nil if csi_u_text_field?(sequence)
        return nil if ctrl_modifier?(sequence[:modifier]) || alt_modifier?(sequence[:modifier]) || super_modifier?(sequence[:modifier])
        return nil unless sequence[:code].between?(32, 126)

        sequence[:code].chr(Encoding::UTF_8)
      end

      def csi_u_text(sequence)
        sequence[:text].to_s.split(":").map do |codepoint|
          character = csi_u_codepoint_character(codepoint)
          return "" unless character

          character
        end.join
      end

      def csi_u_codepoint_character(codepoint)
        codepoint.to_i.chr(Encoding::UTF_8)
      rescue RangeError
        nil
      end

      def handle_modified_csi_u_key(code, modifier)
        return false unless ctrl_modifier?(modifier) || alt_modifier?(modifier)

        normalized_code = ctrl_code_for(code)
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
          when 114
            start_history_search
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

      def ctrl_code_for(code)
        code.to_i.chr.downcase.ord rescue code
      end

      def key_name_for(key)
        cursor_key_name(key) || @reader.console.keys[key]
      end

      def cursor_key_name(key)
        text = key.to_s
        case text
        when TerminalKeys::UP_PATTERN, *TerminalKeys::UP
          :up
        when TerminalKeys::DOWN_PATTERN, *TerminalKeys::DOWN
          :down
        when TerminalKeys::RIGHT_PATTERN, *TerminalKeys::RIGHT
          :right
        when TerminalKeys::LEFT_PATTERN, *TerminalKeys::LEFT
          :left
        when *TerminalKeys::PAGE_UP
          :pageup
        when *TerminalKeys::PAGE_DOWN
          :pagedown
        end
      end

      def ctrl_modifier?(modifier)
        ((modifier.to_i - 1) & 4).positive?
      end

      def alt_modifier?(modifier)
        ((modifier.to_i - 1) & 2).positive?
      end

      def super_modifier?(modifier)
        ((modifier.to_i - 1) & 8).positive?
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

      def handle_bundled_key(key)
        return false unless key.is_a?(String) && key.length > 1

        token = next_key_token(key)
        return false unless token.length < key.length

        queue_pending_keys(key[token.length..])
        yield token
        true
      end

      def next_key_token(keys)
        text = keys.to_s
        text.match(TerminalKeys::CSI_KEY_PATTERN)&.[](0) ||
          text.match(TerminalKeys::SS3_KEY_PATTERN)&.[](0) ||
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

      CTRL_TAB_SEQUENCES = TerminalKeys::CTRL_TAB
      CTRL_SHIFT_TAB_SEQUENCES = TerminalKeys::CTRL_SHIFT_TAB
      SHIFT_TAB_SEQUENCES = TerminalKeys::SHIFT_TAB

      def handle_completion_provider_key(key)
        return false unless key == "\t" && @completion_provider

        result = @completion_provider.call(composer_input, composer_cursor)
        return true unless result

        apply_completion_result(result)
        true
      end

      def apply_completion_result(result)
        range = result[:range] || result["range"] || result.range
        replacement = result[:replacement] || result["replacement"] || result.replacement
        candidates = result[:candidates] || result["candidates"] || result.candidates
        original = composer_input
        before = original[0...range.begin].to_s
        after = original[range.end..].to_s
        self.composer_input = "#{before}#{replacement}#{after}"
        self.composer_cursor = before.length + replacement.to_s.length
        show_completion_candidates(candidates, replacement) if candidates.to_a.length > 1 && replacement.to_s == original[range]
      end

      def show_completion_candidates(candidates, replacement)
        lines = candidates.to_a.first(40)
        text = ["completions:", *lines.map { |candidate| "  #{candidate}" }].join("\n")
        write_completion_transcript_locked(text)
      end

      def write_completion_transcript_locked(text)
        with_synchronized_output_locked do
          clear_prompt_for_output_locked
          write_transcript_text_locked("\n#{text}\n")
          render_prompt_after_output_locked
        end
      end

      def handle_reasoning_key_binding(key)
        return false if @busy || @select_state || @question_state
        return false if file_overlay_visible? || slash_overlay_visible?
        return false if @slash_overlay_dismissed_input && @slash_overlay_dismissed_input == composer_input
        mention_token = active_file_mention_token
        open_token = active_file_open_token
        return false if mention_token && @file_overlay_dismissed_token == mention_token
        return false if open_token && @file_open_dismissed_token == open_token

        case key
        when "\t"
          { reasoning_action: :next }
        when *SHIFT_TAB_SEQUENCES
          { reasoning_action: :previous }
        else
          false
        end
      end

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
        when TerminalKeys::CTRL_T, TerminalKeys::CTRL_T_CSI_U
          { tab_action: :new }
        when TerminalKeys::CTRL_W_CSI_U
          { tab_action: :close }
        else
          ctrl_number_tab_action(key)
        end
      end

      def ctrl_number_tab_action(key)
        match = key.to_s.match(TerminalKeys::CTRL_NUMBER_TAB_PATTERN)
        return false unless match

        { tab_action: :select, index: match[1].to_i - 49 }
      end

      def handle_alt_tab_key_binding(key)
        case key
        when "\et", "\eT"
          { tab_action: :new }
        when *TerminalKeys::ALT_RIGHT
          { tab_action: :next }
        when *TerminalKeys::ALT_LEFT
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
        when TerminalKeys::CTRL_A
          move_to_start_of_line
        when TerminalKeys::CTRL_B
          move_cursor_left
        when TerminalKeys::CTRL_D
          delete_at_cursor_or_exit
        when TerminalKeys::CTRL_E
          move_to_end_of_line
        when TerminalKeys::CTRL_F
          move_cursor_right
        when TerminalKeys::CTRL_K
          kill_line_after_cursor
        when TerminalKeys::CTRL_L
          redraw_screen_locked
        when TerminalKeys::CTRL_U
          kill_line_before_cursor
        when TerminalKeys::CTRL_W
          delete_word_before_cursor
        when TerminalKeys::CTRL_Y
          yank_kill_buffer
        when *TerminalKeys::LEFT
          move_cursor_left
        when *TerminalKeys::RIGHT
          move_cursor_right
        when *TerminalKeys::HOME
          move_to_start_of_line
        when *TerminalKeys::END_KEY
          move_to_end_of_line
        when *TerminalKeys::DELETE
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

      def parse_modified_ansi_key(key)
        if (match = key.to_s.match(TerminalKeys::MODIFIED_CURSOR_PATTERN))
          { type: :cursor, modifier: match[2].to_i, final: match[3] }
        elsif (match = key.to_s.match(TerminalKeys::MODIFIED_DELETE_PATTERN))
          { type: :delete, modifier: match[1].to_i }
        end
      end

      def handle_modified_ansi_key(key)
        sequence = parse_modified_ansi_key(key)
        return false unless sequence

        case sequence[:type]
        when :cursor
          return false unless alt_modifier?(sequence[:modifier])

          case sequence[:final]
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
        when :delete
          alt_modifier?(sequence[:modifier]) ? delete_word_after_cursor : delete_at_cursor
        else
          false
        end
      end

    end
  end
end
