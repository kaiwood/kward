# Namespace for the Kward CLI agent runtime.
module Kward
  class PromptInterface
    # Terminal implementations of the frontend-neutral plugin UI requests.
    module PluginUIRequests
      def request_plugin_ui(kind, payload, cancellation: nil)
        cancellation&.raise_if_cancelled!
        result = case kind.to_sym
                 when :question then ask_user_question(payload.fetch(:questions))
                 when :select then request_plugin_select(payload)
                 when :confirm then request_plugin_confirmation(payload)
                 when :input then request_plugin_input(payload)
                 else raise ArgumentError, "unsupported plugin UI request: #{kind}"
                 end
        cancellation&.raise_if_cancelled!
        result
      end

      private

      def request_plugin_select(payload)
        options = payload.fetch(:options)
        labels = options.map { |option| plugin_option_text(option) }
        selected = with_plugin_ui_modal_state do
          select(payload[:message] || "Choose an option", labels, title: payload.fetch(:title))
        end
        return nil if selected.nil?

        option = options[labels.index(selected)]
        option && option.fetch(:value)
      end

      def request_plugin_confirmation(payload)
        yes = { label: "Yes", description: "Continue." }
        no = { label: "No", description: "Cancel." }
        answers = ask_user_question([
          {
            header: payload.fetch(:title),
            question: payload.fetch(:message),
            options: payload[:default] ? [yes, no] : [no, yes]
          }
        ])
        return false unless answers

        answers.first[:answer].to_s.casecmp?("yes")
      end

      def request_plugin_input(payload)
        with_plugin_ui_modal_state do
          @mutex.synchronize do
            self.composer_input = payload[:default].to_s
            self.composer_cursor = composer_input.length
            @composer.prefill_input = nil
            @composer.clear_attachments
            @pending_keys.clear
            @busy = false
            @asking = true
          end
          label = payload[:placeholder].to_s.empty? ? payload.fetch(:title) : "#{payload.fetch(:title)} · #{payload[:placeholder]}"
          answer = ask("#{label}>")
          answer.is_a?(String) ? answer : nil
        end
      end

      def with_plugin_ui_modal_state
        saved_state = @mutex.synchronize do
          state = begin_question_prompt_state
          @question_prompt_active = true
          state
        end
        yield
      ensure
        finish_question_prompt(saved_state) if saved_state
      end

      def plugin_option_text(option)
        description = option[:description].to_s
        description.empty? ? option.fetch(:label) : "#{option.fetch(:label)} — #{description}"
      end
    end
  end
end
