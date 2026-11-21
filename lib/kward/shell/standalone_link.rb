require "json"
require "socket"

module Kward
  module NativeShell
    # Interpreter side of the private launcher channel. Terminal bytes are
    # never interpreted as protocol messages.
    class StandaloneLink
      def initialize(descriptor)
        @channel = UNIXSocket.for_fd(descriptor)
        @channel.close_on_exec = true
        @channel.sync = true
        $stdout.sync = $stderr.sync = true
        request("ready")
      end

      def begin_command(command, input:)
        request("begin", command: utf8(command), input_pending: !!IO.select([input], nil, nil, 0))
      end

      def finish_command(status)
        request("finish", status: status)
      end

      def clear_context
        request("clear_context")
      end

      def ask(instruction, runtime, input:, output:, error:)
        send_message("ask", instruction: utf8(instruction), cwd: utf8(runtime.cwd))
        loop do
          message = receive
          case message.fetch("type")
          when "run"
            command = message.fetch("command")
            status = runtime.run_shell_agent_command(command, timeout: message.fetch("timeout"), output: output, error: error) do
              echo_command(command, prompt: yield, terminal: error)
              request("running") # Wait for the launcher to drain the echo and start capture.
            end
            send_message("result", status: status, cwd: utf8(runtime.cwd))
          when "answer"
            input.iflush
            answer = message.fetch("text")
            output.puts(answer) unless answer.empty?
            return message["draft"] unless runtime.exited
            return nil
          end
        end
      end

      private

      def echo_command(command, prompt:, terminal:)
        display = command.gsub(/[[:cntrl:]&&[^\n\t]]/) { |character| character.dump[1...-1] }
        terminal.write(prompt.b, display.b)
        terminal.write("\n") unless display.end_with?("\n")
        terminal.flush
      end

      def utf8(value)
        value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def request(type, **data)
        send_message(type, **data)
        receive
      end

      def send_message(type, **data)
        @channel.puts(JSON.generate(data.merge(type: type)))
      end

      def receive
        JSON.parse(@channel.readline)
      end
    end
  end
end
