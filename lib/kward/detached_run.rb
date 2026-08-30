require "thread"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Owns a command that continues after its terminal has been returned to Kward.
  class DetachedRun
    attr_reader :sink

    def initialize(sink:, canceler: nil, &work)
      @sink = sink
      @canceler = canceler
      @mutex = Mutex.new
      @result = nil
      @thread = Thread.new do
        begin
          result = work.call
          @mutex.synchronize { @result = result }
        rescue StandardError => e
          @mutex.synchronize { @result = e }
        end
      end
      @thread.report_on_exception = false
    end

    def complete?
      !@thread.alive?
    end

    def result
      return unless complete?

      @thread.join
      @mutex.synchronize { @result }
    end

    def join(timeout = nil)
      @thread.join(timeout)
    end

    def cancel!
      @canceler&.call
    end
  end
end
