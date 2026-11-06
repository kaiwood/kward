require "fiddle"
require "fcntl"
require "io/nonblock"
require "rbconfig"

module Kward
  module NativeShell
    # Ruby's Process.spawn/exec retry ENOEXEC through /bin/sh, even with argv.
    # Call execve directly, interpreting executable text only with native kwsh.
    module NativeProcess
      EXECVE = Fiddle::Function.new(
        Fiddle::Handle::DEFAULT["execve"],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
        Fiddle::TYPE_INT
      )

      DUP2 = Fiddle::Function.new(Fiddle::Handle::DEFAULT["dup2"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      FCNTL = Fiddle::Function.new(Fiddle::Handle::DEFAULT["fcntl"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      CLOSE = Fiddle::Function.new(Fiddle::Handle::DEFAULT["close"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)

      SIGACTION = Fiddle::Function.new(Fiddle::Handle::DEFAULT["sigaction"],
                                      [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

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

      # Only the standalone executable calls this discovery boundary. Hosted
      # runtimes receive an explicit descriptor map, never the agent's open IOs.
      def self.inherited_descriptors
        (3..9).each_with_object({}) do |descriptor, streams|
          flags = FCNTL.call(descriptor, Fcntl::F_GETFD, 0)
          next if flags < 0 || flags & Fcntl::FD_CLOEXEC != 0
          io = IO.for_fd(descriptor)
          io.close_on_exec = true
          io.sync = true
          streams[descriptor] = io
        end
      end

      def self.ignored_signals
        # Darwin and Linux place the handler pointer first. This buffer exceeds
        # both supported sigaction layouts; querying never changes a disposition.
        action = Fiddle::Pointer.malloc(256, Fiddle::RUBY_FREE)
        Signal.list.filter_map do |name, number|
          next if number.zero? || %w[KILL STOP].include?(name)
          raise SystemCallError.new("sigaction", Fiddle.last_error) if SIGACTION.call(number, nil, action) < 0
          name if action[0, Fiddle::SIZEOF_VOIDP].unpack1("J") == 1 # SIG_IGN
        end
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

      def self.spawn(executable, arguments, environment, cwd:, streams:, mask: nil, hosted: false, signals: {})
        validate(arguments, environment)
        streams.values.compact.uniq.each(&:flush)
        Process.fork { exit!(replace(executable, arguments, environment, cwd: cwd, streams: streams, mask: mask, hosted: hosted, signals: signals)) }
      end

      def self.validate(arguments, environment)
        if arguments.any? { |argument| argument.include?("\0") } || environment.any? { |key, value| key.include?("\0") || value.include?("\0") }
          raise ArgumentError, "NUL bytes are not allowed in process arguments or environment"
        end
      end

      def self.replace(executable, arguments, environment, cwd:, streams:, mask: nil, hosted: false, signals: {})
        validate(arguments, environment)
        load_path = $LOAD_PATH.map { |path| File.expand_path(path) }
        streams.values.compact.uniq.each(&:flush)
        # Keep directory ownership intact even if exec fails after remapping.
        # This runs only in an exec-bound process, never in the agent host.
        if cwd.respond_to?(:enter)
          cwd.protect_descriptors(streams.keys)
          cwd.enter
        else
          Dir.chdir(cwd)
        end
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
        signals.each { |name, handler| Signal.trap(name, handler) }
        begin
          execve(executable, arguments, environment)
        rescue Errno::ENOEXEC
          prefix = File.binread(executable, 4096) || "".b
          raise if prefix.include?("\0") || prefix.start_with?("\x7fELF".b)

          # A fresh VM resets caught signals, closes private CLOEXEC descriptors,
          # and preserves the PID for exec. Only trusted bootstrap code is Ruby;
          # the script and its arguments remain data for the native interpreter.
          bootstrap = <<~RUBY
            $LOAD_PATH.replace(#{load_path.inspect})
            require #{File.expand_path("script_runner", __dir__).inspect}
            hosted = ARGV.shift == "1"
            descriptors = ARGV.shift.split(",").to_h do |value|
              fd = Integer(value)
              io = IO.for_fd(fd)
              io.close_on_exec = true
              io.sync = true
              [fd, io]
            end
            name = ARGV.shift
            exit Kward::NativeShell::ScriptRunner.run(["--", *ARGV], name: name, descriptors: descriptors, own_descriptors: true, hosted: hosted)
          RUBY
          descriptors = streams.filter_map { |fd, io| fd if fd > 2 && io }.join(",")
          execve(RbConfig.ruby, [RbConfig.ruby, "--disable=gems,rubyopt", "-e", bootstrap, "--",
                                hosted ? "1" : "0", descriptors, arguments.first, executable, *arguments.drop(1)], environment)
        end
      rescue StandardError => e
        unless STDERR.closed?
          STDERR.puts("kwsh: #{e.message}")
          STDERR.flush
        end
        e.is_a?(Errno::ENOENT) ? 127 : 126
      end

      def self.execve(executable, arguments, environment)
        argv = arguments.map { |argument| Fiddle::Pointer[argument + "\0"] }
        envp = environment.map { |key, value| Fiddle::Pointer["#{key}=#{value}\0"] }
        argv_pointer = (argv.map(&:to_i) + [0]).pack("J*")
        envp_pointer = (envp.map(&:to_i) + [0]).pack("J*")
        EXECVE.call(executable, argv_pointer, envp_pointer)
        raise SystemCallError.new(executable, Fiddle.last_error)
      end
      private_class_method :execve
    end
  end
end
