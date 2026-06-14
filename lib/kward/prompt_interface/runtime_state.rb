module Kward
  class PromptInterface
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
        return false unless @busy && @queued_count.zero? && @started && @asking

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

    end
  end
end
