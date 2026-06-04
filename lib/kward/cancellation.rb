require "thread"

module Kward
  class Cancellation
    class CancelledError < StandardError; end

    def initialize
      @cancelled = false
      @callbacks = []
      @mutex = Mutex.new
    end

    def cancel!
      callbacks = @mutex.synchronize do
        return if @cancelled

        @cancelled = true
        pending = @callbacks
        @callbacks = []
        pending
      end

      callbacks.each do |callback|
        callback.call
      rescue StandardError
        nil
      end
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    alias canceled? cancelled?

    def raise_if_cancelled!
      raise CancelledError, "cancelled" if cancelled?
    end

    def on_cancel(&block)
      run_now = false
      @mutex.synchronize do
        if @cancelled
          run_now = true
        else
          @callbacks << block
        end
      end

      block.call if run_now
      nil
    end
  end
end
