require_relative "../transport/runtime"

module Kward
  class CLI
    # Foreground transport lifecycle commands.
    module Transports
      private

      def handle_transport_command(arguments)
        command = arguments.first.to_s
        case command
        when "list"
          raise ArgumentError, command_usage("transport") unless arguments.length == 1

          with_transport_runtime { |runtime| print_transport_entries(runtime.manager.list) }
        when "status"
          raise ArgumentError, command_usage("transport") unless arguments.length <= 2

          with_transport_runtime do |runtime|
            entries = arguments.length == 2 ? [runtime.manager.status(arguments[1])] : runtime.manager.status
            print_transport_entries(entries)
          end
        when "run"
          raise ArgumentError, command_usage("transport") unless (2..3).cover?(arguments.length)

          workspace_root = arguments[2] ? expanded_working_directory(arguments[2]) : @working_directory
          run_transport(arguments[1], workspace_root: workspace_root)
        else
          raise ArgumentError, command_usage("transport")
        end
      end

      def print_transport_entries(entries)
        entries.each do |entry|
          @prompt.say("#{entry[:id]}\t#{entry[:state] || "stopped"}")
        end
      end

      def run_transport(name, workspace_root: nil)
        runtime = Transport::Runtime.new(client: ensure_client!)
        runtime.manager.start(name, workspace_root: workspace_root)
        @prompt.say("Transport #{name} is running. Press Ctrl-C to stop.")
        wait_for_transport_shutdown
      ensure
        runtime&.shutdown
      end

      def with_transport_runtime
        runtime = Transport::Runtime.new(client: ensure_client!)
        yield runtime
      ensure
        runtime&.shutdown
      end

      def wait_for_transport_shutdown
        stopped = false
        previous_handlers = {}
        %w[INT TERM].each do |signal|
          previous_handlers[signal] = Signal.trap(signal) { stopped = true }
        end
        sleep 0.1 until stopped
      ensure
        previous_handlers&.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
  end
end
