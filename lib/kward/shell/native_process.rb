require "fiddle"
require "fcntl"
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

      DUP2 = Fiddle::Function.new(Fiddle::Handle::DEFAULT["dup2"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      FCNTL = Fiddle::Function.new(Fiddle::Handle::DEFAULT["fcntl"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      CLOSE = Fiddle::Function.new(Fiddle::Handle::DEFAULT["close"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)

      # Ruby does not expose WCONTINUED on every supported platform.
      # sys/wait.h on Darwin; Linux bits/waitflags.h uses 0x08.
      WAIT_CONTINUED = if Process.const_defined?(:WCONTINUED)
        Process.const_get(:WCONTINUED)
      elsif RUBY_PLATFORM.include?("darwin")
        0x10
      elsif RUBY_PLATFORM.include?("linux")
        0x08
      else
        0
      end

      def self.wait(pid)
        flags = Process::WUNTRACED | WAIT_CONTINUED
        _, status = Process.wait2(pid, flags)
        # A group can resume while its supervisor still holds a stop report.
        # Prefer newer kernel state before propagating that stop back to the group.
        if status.stopped?
          while (update = Process.waitpid2(pid, flags | Process::WNOHANG))
            status = update.last
            break if status.exited? || status.signaled?
          end
        end
        status
      end

      def self.spawn(executable, arguments, environment, cwd:, streams:, mask: nil)
        validate(arguments, environment)
        streams.values.compact.uniq.each(&:flush)
        Process.fork { exit!(replace(executable, arguments, environment, cwd: cwd, streams: streams, mask: mask)) }
      end

      def self.validate(arguments, environment)
        if arguments.any? { |argument| argument.include?("\0") } || environment.any? { |key, value| key.include?("\0") || value.include?("\0") }
          raise ArgumentError, "NUL bytes are not allowed in process arguments or environment"
        end
      end

      def self.replace(executable, arguments, environment, cwd:, streams:, mask: nil)
        validate(arguments, environment)
        streams.values.compact.uniq.each(&:flush)
        # Snapshot all sources before replacing any standard descriptor:
        # `2>&1 >file` must retain the original stdout for stderr.
        copies = streams.transform_values do |io|
          next unless io
          copy = IO.for_fd(io.fcntl(Fcntl::F_DUPFD, 32))
          copy.close_on_exec = true
          copy
        end
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
        copies.each do |descriptor, source|
          next if descriptor < 3
          if source
            raise SystemCallError.new("dup2", Fiddle.last_error) if DUP2.call(source.fileno, descriptor) < 0
            FCNTL.call(descriptor, Fcntl::F_SETFD, 0)
            flags = FCNTL.call(descriptor, Fcntl::F_GETFL, 0)
            FCNTL.call(descriptor, Fcntl::F_SETFL, flags & ~Fcntl::O_NONBLOCK)
          else
            CLOSE.call(descriptor)
          end
        end
        copies.values.compact.each(&:close)
        File.umask(mask) if mask
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
        e.is_a?(Errno::ENOENT) ? 127 : 126
      end
    end
  end
end
