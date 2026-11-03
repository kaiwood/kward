require "fiddle"
require "io/nonblock"

module Kward
  module NativeShell
    # Ruby's Process.spawn/exec retry ENOEXEC through /bin/sh, even with argv.
    # Call execve directly so unsupported executable formats fail closed.
    module NativeProcess
      EXECVE = Fiddle::Function.new(
        Fiddle::Handle::DEFAULT["execve"],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
        Fiddle::TYPE_INT
      )

      def self.spawn(executable, arguments, environment, cwd:, streams:)
        streams.values.compact.uniq.each(&:flush)
        Process.fork do
          begin
            Signal.trap("INT", "DEFAULT")
            # Snapshot all sources before replacing any standard descriptor:
            # `2>&1 >file` must retain the original stdout for stderr.
            copies = streams.transform_values { |io| io&.dup }
            [STDIN, STDOUT, STDERR].each_with_index do |standard, descriptor|
              source = copies[descriptor]
              if source
                standard.reopen(source)
                standard.close_on_exec = false
                standard.nonblock = false
                standard.sync = true
              else
                standard.close
              end
            end
            copies.values.compact.each(&:close)
            Dir.chdir(cwd)
            argv = arguments.map { |argument| Fiddle::Pointer[argument + "\0"] }
            envp = environment.map { |key, value| Fiddle::Pointer["#{key}=#{value}\0"] }
            argv_pointer = (argv.map(&:to_i) + [0]).pack("J*")
            envp_pointer = (envp.map(&:to_i) + [0]).pack("J*")
            EXECVE.call(executable, argv_pointer, envp_pointer)
            raise SystemCallError.new(executable, Fiddle.last_error)
          rescue StandardError => e
            unless STDERR.closed?
              hint = e.is_a?(Errno::ENOEXEC) ? "; use kwsh <file> for native scripts" : ""
              STDERR.puts("kwsh: #{e.message}#{hint}")
              STDERR.flush
            end
            exit!(e.is_a?(Errno::ENOENT) ? 127 : 126)
          end
        end
      end
    end
  end
end
