module Kward
  module Workers
    # Drains a running worker's accumulated event history into a frontend renderer.
    class LiveView
      FINISHED_STATUSES = %w[ready failed cancelled archived].freeze

      def initialize(worker:, agent:, renderer:, poll_interval: 0.05)
        @worker = worker
        @agent = agent
        @renderer = renderer
        @poll_interval = poll_interval
        @seen_events = worker.event_history.length
        @stop = false
        @thread = nil
      end

      attr_reader :worker, :agent

      def start
        @thread = Thread.new { run }
        @thread.report_on_exception = false
        self
      end

      def stop
        @stop = true
        @thread&.join(0.2)
      end

      private

      def run
        until @stop
          events = @worker.event_history[@seen_events..] || []
          events.each { |event| @renderer.call(event, @agent) }
          @seen_events += events.length
          @renderer.call(:flush, @agent) if finished?
          break if finished?

          sleep @poll_interval
        end
      end

      def finished?
        FINISHED_STATUSES.include?(@worker.status)
      end
    end
  end
end
