require "io/console"
require "json"
require "socket"
require_relative "native_runtime"

module Kward
  module NativeShell
    # A single-threaded interpreter process owns the terminal and mutable shell
    # state. Requests/state use a private socket, never terminal input/output.
    class Worker
      def self.run(descriptor)
        control = UNIXSocket.for_fd(descriptor)
        control.close_on_exec = true
        control.sync = true
        $stdout.sync = true
        $stderr.sync = true
        runtime = nil
        Signal.trap("INT") { raise Interrupt }

        while (line = control.gets)
          request = JSON.parse(line)
          runtime ||= Runtime.new(cwd: request.fetch("cwd"), env: ENV.to_h, aliases: request.fetch("aliases", {}))
          status = begin
            $stdin.echo = true
            if request["config"]
              apply_configuration(runtime, request["config"])
            elsif request["suppress_git_pager"]
              runtime.with_pager_suppressed { runtime.run(request.fetch("command")) }
            else
              runtime.run(request.fetch("command"))
            end
          rescue Interrupt
            130
          ensure
            $stdin.echo = false
          end
          $stdout.write("#{request.fetch('marker')}:#{status}:\n")
          control.puts(JSON.generate(cwd: runtime.cwd, env: runtime.environment, aliases: runtime.aliases, exited: runtime.exited))
        end
      rescue EOFError, Errno::EIO, Errno::EPIPE
        nil
      end

      def self.apply_configuration(runtime, config)
        config.fetch("env", {}).each do |key, value|
          status = runtime.run("export #{key}=#{Shellwords.escape(value)}")
          return status unless status.zero?
        end
        runtime.aliases.merge!(config.fetch("aliases", {}))
        runtime.run(":")
      end
      private_class_method :apply_configuration
    end
  end
end

Kward::NativeShell::Worker.run(Integer(ARGV.fetch(0))) if $PROGRAM_NAME == __FILE__
