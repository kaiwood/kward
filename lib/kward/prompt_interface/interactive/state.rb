# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # State lifecycle for interactive mode. Manages entering and exiting the
    # canvas-based render loop, including composer snapshot save/restore.
    module InteractiveState
      private

      def interactive_canvas_width
        [screen_width - 6, 1].max
      end

      def route_interactive_key(key)
        return false unless interactive_active_locked?

        interactive_key = interactive_csi_u_key(key)
        unless interactive_key == false
          return force_interactive_exit if interactive_key == :force_exit

          @interactive_state[:controller].push_key(interactive_key)
          return true
        end

        name = key_name_for(key) if key.is_a?(String) && key.length >= 1
        return force_interactive_exit if key == "\x03" || name == :escape

        @interactive_state[:controller].push_key(name || key)
        true
      end

      def interactive_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        return :force_exit if code == 27 || (code.to_i.chr.downcase == "c" && ctrl_modifier?(modifier))
        return :return if code == 13
        return :backspace if [8, 127].include?(code)
        return :space if code == 32 && !ctrl_modifier?(modifier) && !alt_modifier?(modifier) && !super_modifier?(modifier)

        text = csi_u_printable_text(sequence)
        return text if text

        false
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
