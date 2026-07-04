require "json"
require "open3"
require "timeout"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model Context Protocol client support.
  module MCP
    # JSON-RPC transport for local MCP servers that communicate over stdio.
    class StdioTransport
      DEFAULT_TIMEOUT_SECONDS = 10

      def initialize(command:, args: [], env: {}, timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
        @command = command.to_s
        @args = Array(args).map(&:to_s)
        @env = env || {}
        @timeout_seconds = timeout_seconds || DEFAULT_TIMEOUT_SECONDS
        @mutex = Mutex.new
        @started = false
      end

      def request(method, params = nil)
        @mutex.synchronize do
          start
          id = next_id
          write_message({ jsonrpc: "2.0", id: id, method: method, params: params }.compact)
          read_response(id)
        end
      end

      def notify(method, params = nil)
        @mutex.synchronize do
          start
          write_message({ jsonrpc: "2.0", method: method, params: params }.compact)
        end
      end

      def close
        @stdin&.close unless @stdin&.closed?
        @stdout&.close unless @stdout&.closed?
        @stderr&.close unless @stderr&.closed?
        @stderr_thread&.kill
        terminate_process
      rescue IOError
        nil
      end

      private

      def terminate_process
        return unless @wait_thread&.alive?

        Process.kill("TERM", @wait_thread.pid)
        @wait_thread.join(1)
        Process.kill("KILL", @wait_thread.pid) if @wait_thread.alive?
      rescue Errno::ESRCH, IOError
        nil
      end

      def start
        return if @started
        raise ArgumentError, "MCP server command is required" if @command.empty?

        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env, @command, *@args)
        @stderr_thread = Thread.new { @stderr.each_line { |_line| } }
        @started = true
      rescue SystemCallError => e
        raise "Failed to start MCP server #{@command}: #{e.message}"
      end

      def next_id
        @next_id ||= 0
        @next_id += 1
      end

      def write_message(message)
        @stdin.write(JSON.generate(message))
        @stdin.write("\n")
        @stdin.flush
      rescue IOError, Errno::EPIPE => e
        raise "MCP server #{@command} is not accepting requests: #{e.message}"
      end

      def read_response(expected_id)
        Timeout.timeout(@timeout_seconds) do
          loop do
            line = @stdout.gets
            raise "MCP server #{@command} closed stdout" unless line

            message = JSON.parse(line)
            next unless message["id"] == expected_id

            error = message["error"]
            raise "MCP request failed: #{error["message"] || error.inspect}" if error

            return message["result"] || {}
          end
        end
      rescue JSON::ParserError
        raise "MCP server #{@command} returned invalid JSON"
      rescue Timeout::Error
        raise "MCP server #{@command} did not respond within #{@timeout_seconds} seconds"
      end
    end
  end
end
