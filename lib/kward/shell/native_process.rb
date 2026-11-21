require "fiddle"
require "fcntl"
require "io/nonblock"
require "rbconfig"
require_relative "native_exec_state"

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

      def self.standalone(arguments, name:, program: "kwsh", edit_lines: false, load_rc: false, shell_agent: false)
        inherited = inherited_descriptors
        relay = shell_agent && standalone_terminal?(arguments)
        # Ruby owns private wake-up descriptors before this script starts.
        # Re-exec the trusted VM with 3–9 occupied so its new private handles
        # cannot collide with shell redirections. PID and user IOs are retained.
        bootstrap = <<~RUBY
          $LOAD_PATH.replace(#{$LOAD_PATH.map { |path| File.expand_path(path) }.inspect})
          require #{File.expand_path("script_runner", __dir__).inspect}
          descriptors = ARGV.shift.split(",").to_h do |value|
            fd = Integer(value)
            source = IO.for_fd(fd, autoclose: false)
            io = IO.for_fd(source.fcntl(Fcntl::F_DUPFD, 32))
            io.close_on_exec = true
            io.sync = true
            [fd, io]
          end
          File.open(File::NULL, "r+") do |guard|
            (3..9).each do |fd|
              result = Kward::NativeShell::NativeProcess::DUP2.call(guard.fileno, fd)
              raise SystemCallError.new("dup2", Fiddle.last_error) if result < 0
              IO.for_fd(fd, autoclose: false).close_on_exec = true
            end
          end
          $0 = ARGV.shift
          link = if #{relay.inspect}
            require #{File.expand_path("standalone_link", __dir__).inspect}
            Kward::NativeShell::StandaloneLink.new(30)
          end
          exit Kward::NativeShell::ScriptRunner.run(ARGV, descriptors: descriptors, own_descriptors: true, process_owned: true,
                                                   program: #{program.inspect}, edit_lines: #{edit_lines.inspect}, load_rc: #{load_rc.inspect}, shell_link: link)
        RUBY
        mappings = (3..9).to_h { |fd| [fd, inherited.fetch(fd) { [File::NULL, File::RDWR] }] }
        # Only the trusted Ruby executable uses Ruby's exec API; user programs
        # still go through execve and the native-only ENOEXEC path below.
        ruby_arguments = [RbConfig.ruby, "--disable=gems,rubyopt", "-e", bootstrap, "--", inherited.keys.join(","), name, *arguments]
        if relay
          require_relative "standalone_terminal"
          exit StandaloneTerminal.new.run(ruby_arguments, mappings)
        end
        Kernel.exec(*ruby_arguments, **mappings)
      end

      def self.standalone_terminal?(arguments)
        return false unless $stdin.tty? && $stdout.tty? && $stderr.tty?
        return false unless Process.uid == Process.euid && Process.gid == Process.egid

        require_relative "native_invocation"
        Invocation.parse(arguments).prompt?($stdin, $stderr)
      rescue ArgumentError
        false # Let ScriptRunner report invocation errors as usual.
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

      def self.replace(executable, arguments, environment, cwd:, streams:, mask: nil, hosted: false, signals: {}, recover: false)
        validate(arguments, environment)
        load_path = $LOAD_PATH.map { |path| File.expand_path(path) }
        streams.values.compact.uniq.each(&:flush)
        # Keep directory ownership intact even if exec fails after remapping.
        # This runs only in an exec-bound process, never in the agent host.
        if cwd.respond_to?(:enter)
          cwd.protect_descriptors(streams.keys)
        end
        if recover
          streams.each_key do |fd|
            next if fd < 3 || FCNTL.call(fd, Fcntl::F_GETFD, 0) < 0
            # Embedded callers must not overwrite Ruby's live internal handles.
            IO.for_fd(fd, autoclose: false)
          end
          state = ExecState.new(([0, 1, 2] + streams.keys + streams.values.compact.map(&:fileno)).uniq)
        end
        if cwd.respond_to?(:enter)
          cwd.enter
        else
          Dir.chdir(cwd)
        end
        # Snapshot all sources before replacing any standard descriptor:
        # `2>&1 >file` must retain the original stdout for stderr.
        copies = {}
        streams.each do |descriptor, io|
          unless io
            copies[descriptor] = nil
            next
          end
          copy = IO.for_fd(io.fcntl(Fcntl::F_DUPFD, 32))
          copy.close_on_exec = true
          copies[descriptor] = copy
        end
        [STDIN, STDOUT, STDERR].each_with_index do |standard, descriptor|
          source = copies[descriptor]
          if source
            standard.reopen(source)
            standard.close_on_exec = false
            standard.nonblock = false
            standard.sync = true
          elsif recover
            standard.reopen(File::NULL, descriptor.zero? ? "r" : "w")
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
        signals.each do |name, handler|
          previous = Signal.trap(name, handler)
          state.signals[name] = previous if state
        end
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
            exit Kward::NativeShell::ScriptRunner.run(["--", *ARGV], name: name, descriptors: descriptors, own_descriptors: true, hosted: hosted, process_owned: true)
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
      ensure
        begin
          state&.restore
        ensure
          state&.close
          copies&.each_value { |io| io.close if io && !io.closed? }
        end
      end

      def self.redirect_standard_streams(streams)
        copies = {}
        streams.each do |fd, io|
          next unless fd < 3
          copies[fd] = io && IO.for_fd(io.fcntl(Fcntl::F_DUPFD, 32))
          copies[fd].close_on_exec = true if copies[fd]
        end
        copies.each do |fd, source|
          standard = [STDIN, STDOUT, STDERR][fd]
          if source
            standard.reopen(source)
            standard.sync = true
          else
            # POSIX permits closed standard descriptors to be reopened on an
            # unspecified file. Keep the standalone prompt's Ruby IOs usable.
            standard.reopen(File::NULL, fd.zero? ? "r" : "w")
          end
        end
      ensure
        copies&.each_value { |io| io.close if io && !io.closed? }
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
