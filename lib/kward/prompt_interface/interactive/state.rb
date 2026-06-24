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

        if key == "\x03"
          @interactive_state[:controller].force_exit
          return true
        end

        name = key_name_for(key) if key.is_a?(String) && key.length >= 1
        @interactive_state[:controller].push_key(name || key)
        true
      end

      def handle_interactive_key(key)
        route_interactive_key(key)
        nil
      end
    end
  end
end
