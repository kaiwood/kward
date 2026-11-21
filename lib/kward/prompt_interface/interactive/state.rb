# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # State lifecycle for interactive mode. Manages entering and exiting the
    # canvas-based render loop, including composer snapshot save/restore.
    module InteractiveState
      private

      def interactive_canvas_width(width = screen_width)
        [width - 6, 1].max
      end

      def route_interactive_key(key)
        return false unless interactive_active_locked?

        interactive_key = if (sequence = parse_csi_u_key(key))
          interactive_csi_u_key(sequence)
        elsif key == TerminalKeys::ESCAPE
          :force_exit
        elsif key == TerminalKeys::CTRL_C
          :ctrl_c
        else
          key_name_for(key) || key
        end
        return force_interactive_exit if interactive_key == :force_exit

        @interactive_state[:controller].push_key(interactive_key) if interactive_key
        true
      end

      def interactive_csi_u_key(sequence)
        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) unless sequence[:remaining].to_s.empty?
        return if sequence[:event_type] == 3 || TerminalKeys::CSI_U_MODIFIER_KEY_CODES.cover?(code)

        # Ignore Caps Lock and Num Lock when matching a key binding.
        held_modifiers = (modifier - 1) & 0b111111
        return :force_exit if code == 27 && held_modifiers.zero?
        return :ctrl_c if [67, 99].include?(code) && held_modifiers == 4
        return :return if code == 13
        return :backspace if [8, 127].include?(code)
        return :space if code == 32 && !ctrl_modifier?(modifier) && !alt_modifier?(modifier) && !super_modifier?(modifier)

        csi_u_printable_text(sequence) || sequence[:sequence]
      end

      def force_interactive_exit
        @interactive_state[:controller].force_exit
        true
      end

      def handle_interactive_key(key)
        route_interactive_key(key)
        nil
      end
    end
  end
end
