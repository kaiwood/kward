# Namespace for the Kward CLI agent runtime.
module Kward
  # Runtime metadata shown in the prompt footer and status UI.
  class PromptInterface
    # Runtime footer, model, persona, and session state shown by the prompt interface.
    module RuntimeState
      private

      def reset_spinner_locked
        @spinner_frame_index = 0
        @last_spinner_tick = monotonic_now
      end

      def normalize_busy_activity(activity)
        text = activity.to_s.gsub(/\s+/, " ").strip
        text.empty? ? "streaming" : text
      end

      def tick_spinner_locked
        return false unless spinner_active?

        now = monotonic_now
        elapsed = now - @last_spinner_tick
        return false if elapsed < SPINNER_INTERVAL

        steps = (elapsed / SPINNER_INTERVAL).floor
        @spinner_frame_index = (@spinner_frame_index + steps) % SPINNER_FRAMES.length
        @last_spinner_tick += steps * SPINNER_INTERVAL
        true
      end

      def spinner_frame
        SPINNER_FRAMES[@spinner_frame_index % SPINNER_FRAMES.length]
      end

      def spinner_active?
        busy = @busy || (@select_state && @select_state[:busy_activity])
        busy && @queued_count.zero? && @started && @asking
      end

      def tick_footer_locked
        return false unless @footer && @started && @asking

        now = monotonic_now
        elapsed = now - @last_footer_refresh
        return false if elapsed < FOOTER_REFRESH_INTERVAL

        steps = (elapsed / FOOTER_REFRESH_INTERVAL).floor
        @last_footer_refresh += steps * FOOTER_REFRESH_INTERVAL
        true
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end


      def colored(text, *styles)
        ANSI.colorize(text, *styles, enabled: @color_enabled)
      end

      def normalize_tab_keybindings(value)
        text = value.to_s.downcase
        return "ctrl" if text == "ctrl"
        return "alt" if text == "alt"

        RbConfig::CONFIG["host_os"].to_s.downcase.include?("darwin") ? "ctrl" : "alt"
      end

      def normalize_editor_mode(value)
        text = value.to_s.downcase
        return "nano" if text == "default"

        %w[nano emacs vi].include?(text) ? text : "nano"
      end

      def tab_action_result?(result)
        result.is_a?(Hash) && result[:tab_action]
      end

    end
  end
end
