require "thread"
require "time"

module Kward
  class Steering
    Event = Struct.new(:input, :created_at, keyword_init: true)

    def initialize(on_submit: nil)
      @listeners = []
      @listeners << on_submit if on_submit
      @events = []
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def on_submit(&block)
      return unless block

      @mutex.synchronize { @listeners << block }
      nil
    end

    def submit(input)
      event = Event.new(input: input, created_at: Time.now.utc.iso8601(3))
      listeners = nil
      @mutex.synchronize do
        @events << event
        listeners = @listeners.dup
        @condition.broadcast
      end
      listeners.each { |listener| listener.call(event) }
      event
    end

    def wait(after: 0, timeout: nil)
      deadline = timeout ? Time.now + timeout.to_f : nil
      @mutex.synchronize do
        loop do
          event = @events[after]
          return event if event

          if deadline
            remaining = deadline - Time.now
            return nil if remaining <= 0

            @condition.wait(@mutex, remaining)
          else
            @condition.wait(@mutex)
          end
        end
      end
    end
  end
end
