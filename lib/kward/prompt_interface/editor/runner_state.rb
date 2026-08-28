require "digest"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Ephemeral state for the output of an editor runner.
  class PromptInterface
    class EditorRunnerState
      attr_reader :language, :source_digest

      def initialize(language:, source:)
        @language = language.to_sym
        @source_digest = Digest::SHA256.hexdigest(source.to_s)
        @mutex = Mutex.new
        @running = true
        @cancel_requested = false
        @result = nil
        @error = nil
        @scroll_row = 0
      end

      def running?
        @mutex.synchronize { @running }
      end

      def cancel_requested?
        @mutex.synchronize { @cancel_requested }
      end

      def cancel
        @mutex.synchronize { @cancel_requested = true }
      end

      def complete(result)
        @mutex.synchronize do
          @result = result
          @running = false
        end
      end

      def fail(error)
        @mutex.synchronize do
          @error = error
          @running = false
        end
      end

      def result
        @mutex.synchronize { @result }
      end

      def error
        @mutex.synchronize { @error }
      end

      def output_text
        @mutex.synchronize do
          return @error.message.to_s if @error

          @result&.output.to_s
        end
      end

      def scroll_row
        @mutex.synchronize { @scroll_row }
      end

      def set_scroll_row(row, maximum:)
        @mutex.synchronize do
          @scroll_row = [[row.to_i, 0].max, maximum.to_i].min
        end
      end

      def scroll_by(delta, maximum:)
        set_scroll_row(scroll_row + delta.to_i, maximum: maximum)
      end
    end
  end
end
