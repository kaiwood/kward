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
        text.empty? ? "thinking" : text
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

      def completion_status(status)
        text = case status&.to_sym
        when :success
          ["✓ Complete", :success]
        when :failed
          ["× Failed", :failure]
        when :cancelled
          ["– Cancelled", :metadata]
        else
          return nil
        end
        { text: text.first, style: text.last, expires_at: monotonic_now + COMPLETION_DISPLAY_SECONDS }
      end

      def response_arriving?
        return false unless @response_arrival_until

        if monotonic_now >= @response_arrival_until
          @response_arrival_until = nil
          return false
        end
        true
      end

      def tick_completion_locked
        return false unless @completion_status
        return false if monotonic_now < @completion_status[:expires_at]

        @completion_status = nil
        true
      end

      def tick_footer_locked
        return false unless @footer && @started && @asking
        return false unless footer_refresh_due?

        previous_text = @cached_footer_text
        refresh_footer_text_locked
        previous_text != @cached_footer_text
      end

      def cached_footer_text
        return "" unless @footer

        refresh_footer_text_locked if footer_refresh_due?
        @cached_footer_text.to_s
      end

      def footer_refresh_due?
        @last_footer_refresh.nil? || monotonic_now - @last_footer_refresh >= FOOTER_REFRESH_INTERVAL
      end

      def refresh_footer_text_locked
        @cached_footer_text = @footer.call.to_s.gsub(/\s+/, " ").strip
      rescue StandardError
        @cached_footer_text = ""
      ensure
        @last_footer_refresh = monotonic_now
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

      def normalize_project_browser_icon_theme(value)
        value.to_s == "nerd-font" ? "nerd-font" : "off"
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

      def editor_prompt_action?(result)
        result.is_a?(Hash) && result[:editor_prompt]
      end

      def prompt_action_result?(result)
        tab_action_result?(result) || reasoning_action_result?(result) || editor_prompt_action?(result)
      end

    end
  end
end
