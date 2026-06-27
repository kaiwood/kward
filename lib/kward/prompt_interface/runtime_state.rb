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

      def cached_composer_status_text
        return nil unless @composer_status

        now = monotonic_now
        elapsed = now - @last_composer_status_refresh.to_f
        if @cached_composer_status_text.nil? || elapsed >= COMPOSER_STATUS_REFRESH_INTERVAL
          text = @composer_status.call.to_s
          @cached_composer_status_text = text.empty? ? nil : status_composer_text(text)
          @last_composer_status_refresh = now
        end
        @cached_composer_status_text
      rescue StandardError
        @cached_composer_status_text = nil
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
        EditorMode.normalize(value)
      end

      def normalize_editor_line_numbers(value)
        EditorMode.normalize_line_numbers(value)
      end

      def tab_action_result?(result)
        result.is_a?(Hash) && result[:tab_action]
      end

      def reasoning_action_result?(result)
        result.is_a?(Hash) && result[:reasoning_action]
      end

      def prompt_action_result?(result)
        tab_action_result?(result) || reasoning_action_result?(result)
      end

    end
  end
end
