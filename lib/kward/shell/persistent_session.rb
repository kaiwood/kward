require "io/console"
require "pty"
require "securerandom"
require "shellwords"
require_relative "../ansi"
require_relative "kwsh"
require_relative "kwshrc"
require_relative "../local_pty_command_runner"
require_relative "../detached_run"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Owns one interactive shell process and serializes user and agent commands.
  #
  # The process is kept alive between commands so shell variables, functions,
  # aliases, directory changes, and child-shell state belong to one session.
  class PersistentShellSession
    Result = Kwsh::Result
    InteractiveResult = Struct.new(:exit_status, :input_forwarded, :tab_action, :background, keyword_init: true)

    class CommandInterrupted < StandardError
      attr_reader :protocol

      def initialize(protocol)
        @protocol = protocol
        super("The embedded shell did not respond to an interrupt.")
      end
    end

    READ_SIZE = 4_096
    STARTUP_TIMEOUT_SECONDS = 5
    STTY_COMMAND = if File.executable?("/bin/stty")
      "/bin/stty"
    elsif File.executable?("/usr/bin/stty")
      "/usr/bin/stty"
    else
      "stty"
    end.freeze
    STATEFUL_COMMANDS = %w[alias cd export pwd unset unalias].freeze

    attr_reader :cwd, :last_command, :timeout_seconds

    def initialize(cwd: Dir.pwd, env: ENV.to_h, shell: Kwsh::DEFAULT_SHELL, configured_env: {}, aliases: {}, timeout_seconds: Kwsh::DEFAULT_TIMEOUT_SECONDS, max_output_bytes: Kwsh::DEFAULT_MAX_OUTPUT_BYTES, window_size_provider: nil)
      @cwd = File.expand_path(cwd.to_s.empty? ? Dir.pwd : cwd.to_s)
      @base_env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @configured_env = configured_env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @aliases = aliases.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @shell = shell.to_s.empty? ? Kwsh::DEFAULT_SHELL : shell.to_s
      @timeout_seconds = timeout_seconds.to_i.positive? ? timeout_seconds.to_i : Kwsh::DEFAULT_TIMEOUT_SECONDS
      @max_output_bytes = max_output_bytes.to_i.positive? ? max_output_bytes.to_i : Kwsh::DEFAULT_MAX_OUTPUT_BYTES
      @window_size_provider = window_size_provider
      @last_command = nil
      @last_result = nil
      @command_mutex = Mutex.new
      @write_mutex = Mutex.new
      @marker_counter = 0
      @marker_prefix = "__KWARD_SHELL_#{SecureRandom.hex(16)}_"
      @closed = false
      @routing_shell = build_routing_shell
      @env = @routing_shell.child_env

      start_process
      initialize_protocol
    rescue StandardError
      close
      raise
    end

    def command_shell
      @shell
    end

    def child_env(interactive: false)
      @env.dup
    end

    def prompt_label
      "Shell #{display_cwd} $"
    end

    def run(input, cancellation: nil, &block)
      command = input.to_s.strip
      return Result.new(output: "", exit_status: 0) if command.empty?

      expanded_command = expand_alias(command)
      words = shell_words(expanded_command)
      sync_runtime_state(words)
      result = if words.empty?
        Result.new(output: "", exit_status: 0)
      elsif words.first == "clear"
        Result.new(output: "", exit_status: 0, clear: true)
      elsif %w[exit logout].include?(words.first)
        exit_result(command, words)
      elsif words.first == "capture"
        capture_result(command, expanded_command, cancellation: cancellation, &block)
      elsif words.first == "pty"
        interactive_result(command, expanded_command)
      elsif %w[source .].include?(words.first)
        source_result(command, words)
      elsif (editor_result = editor_command_result(command))
        editor_result
      elsif stateful_command?(words)
        execute_command(expanded_command, display_command: command, cancellation: cancellation, &block)
      else
        Result.new(output: command_echo(command), exit_status: 0, interactive_command: expanded_command)
      end
      remember_result(command, result)
      result
    rescue ArgumentError => e
      result = Result.new(output: "#{command_echo(command)}kwsh: #{e.message}\n", exit_status: 2)
      remember_result(command, result)
      result
    end

    # Runs a command for the shell assistant without handing it the terminal.
    def run_for_agent(input, timeout_seconds: nil, cancellation: nil)
      command = input.to_s.strip
      return run(command, cancellation: cancellation) if command.empty?

      result = run(command, cancellation: cancellation)
      return result unless result.interactive_command

      result = execute_command(
        result.interactive_command,
        display_command: command,
        timeout_seconds: timeout_seconds,
        cancellation: cancellation,
        suppress_git_pager: true
      )
      remember_result(command, result)
      result
    end

    # Runs an external command through the same persistent shell process while
    # the caller owns the terminal.
    def run_interactive(command, input:, sink:, tab_action_handler: nil, on_detach: nil)
      protocol = with_raw_input(input) do
        execute_protocol(command, input: input, sink: sink, tab_action_handler: tab_action_handler, on_detach: on_detach)
      end
      update_cwd(protocol[:cwd]) unless protocol[:background]
      InteractiveResult.new(
        exit_status: protocol[:status] || 1,
        input_forwarded: protocol[:input_forwarded],
        tab_action: protocol[:tab_action],
        background: protocol[:background]
      )
    ensure
      sink.finish if sink.respond_to?(:finish)
    end

    # Records the safe output captured after an interactive terminal handoff.
    def record_interactive_result(output:, exit_status:)
      return unless @last_command

      @last_result = Result.new(output: ANSI.sanitize_transcript(output.to_s), exit_status: exit_status)
    end

    # Returns bounded shell state for an explicit shell-agent prompt.
    def context_snapshot(max_output_bytes: Kwsh::CONTEXT_OUTPUT_BYTES)
      {
        cwd: @cwd,
        last_command: @last_command,
        exit_status: @last_result&.exit_status,
        last_output: context_output(@last_result&.output, max_output_bytes)
      }
    end

    def complete(input, cursor)
      completion_shell.complete(input, cursor)
    end

    def expand_alias(command, interactive: false)
      @routing_shell.expand_alias(command, interactive: interactive)
    end

    def editor_command_result(command, display_command: command)
      @routing_shell.editor_command_result(command, display_command: display_command)
    end

    def close
      return if @closed

      @closed = true
      begin
        terminate_process_group(@pid) if @pid
      ensure
        @write_mutex.synchronize do
          @reader&.close unless @reader&.closed?
          @writer&.close unless @writer&.closed?
        end
        @process_thread&.join(0.5)
        @process_thread&.kill if @process_thread&.alive?
        @pid = nil
      end
    rescue StandardError
      nil
    end

    private

    def with_raw_input(input)
      return yield unless input.respond_to?(:raw)

      yielded = false
      input.raw do
        yielded = true
        yield
      end
    rescue Errno::ENOTTY
      raise if yielded

      yield
    end

    def build_routing_shell
      Kwsh.new(
        cwd: @cwd,
        env: @env || @base_env,
        shell: @shell,
        configured_env: @env ? {} : @configured_env,
        aliases: @aliases,
        timeout_seconds: @timeout_seconds,
        max_output_bytes: @max_output_bytes
      )
    end

    def completion_shell
      @completion_shell ||= build_routing_shell
    end

    def start_process
      ready = Queue.new
      process_env = @env.merge("PS1" => "", "PS2" => "")
      @process_thread = Thread.new do
        begin
          PTY.spawn(process_env, @shell, "-i", chdir: @cwd) do |reader, writer, pid|
            @reader = reader
            @writer = writer
            @pid = pid
            ready << true
            sleep 0.05 until @closed
          end
        rescue StandardError => e
          ready << e
        end
      end
      started = ready.pop
      raise started if started.is_a?(Exception)

      @reader.sync = true
      @writer.sync = true
      update_window_size
    end

    def initialize_protocol
      protocol = execute_protocol(":", timeout_seconds: STARTUP_TIMEOUT_SECONDS, max_output_bytes: nil)
      raise IOError, "The embedded shell did not start." unless protocol[:status] == 0

      update_cwd(protocol[:cwd])
    end

    def execute_protocol(command, input: nil, sink: nil, timeout_seconds: nil, max_output_bytes: @max_output_bytes, cancellation: nil, suppress_git_pager: false, tab_action_handler: nil, on_detach: nil)
      @command_mutex.synchronize do
        ensure_open
        cancellation&.raise_if_cancelled!
        marker = next_marker
        write_protocol_command(command, marker, suppress_git_pager: suppress_git_pager)
        read_until_marker(
          marker,
          input: input,
          sink: sink,
          timeout_seconds: timeout_seconds,
          max_output_bytes: max_output_bytes,
          cancellation: cancellation,
          tab_action_handler: tab_action_handler,
          on_detach: on_detach
        )
      end
    rescue CommandInterrupted => e
      restart_process unless e.protocol[:background]
      e.protocol
    rescue IOError
      close
      raise
    end

    def write_protocol_command(command, marker, suppress_git_pager: false)
      escaped_command = Shellwords.escape(command.to_s)
      pager_setup, pager_restore = git_pager_protocol(marker, suppress: suppress_git_pager)
      protocol = <<~SHELL
        if true; then
          if [ -n "${ZSH_VERSION-}" ]; then unsetopt zle 2>/dev/null; fi
          PS1=''
          PS2=''
          export PS1 PS2
          #{STTY_COMMAND} echo
          #{pager_setup}
          if eval #{escaped_command}; then __kward_status=$?; else __kward_status=$?; fi
          #{pager_restore}
          __kward_cwd=$(pwd 2>/dev/null)
          #{STTY_COMMAND} -echo
          printf '#{marker}:%s:%s\\n' "$__kward_status" "$__kward_cwd"
        fi
      SHELL
      write_raw(protocol)
    end

    def git_pager_protocol(marker, suppress:)
      return ["", ""] unless suppress

      was_set = "#{marker}_GIT_PAGER_WAS_SET"
      saved_value = "#{marker}_GIT_PAGER_VALUE"
      setup = <<~SHELL
        #{was_set}=${GIT_PAGER+x}
        #{saved_value}=${GIT_PAGER-}
        GIT_PAGER=cat
        export GIT_PAGER
      SHELL
      restore = <<~SHELL
        if [ "$#{was_set}" = x ]; then
          GIT_PAGER="$#{saved_value}"
          export GIT_PAGER
        else
          unset GIT_PAGER
        fi
        unset #{was_set} #{saved_value}
      SHELL
      [setup, restore]
    end

    def read_until_marker(marker, input:, sink:, timeout_seconds:, max_output_bytes:, cancellation:, tab_action_handler: nil, on_detach: nil, initial_buffer: nil)
      buffer = initial_buffer ? initial_buffer.dup : +"".b
      captured = +"".b
      captured_bytes = 0
      truncated = false
      input_forwarded = false
      timed_out = false
      interrupted = false
      deadline = timeout_seconds && (Time.now + effective_timeout(timeout_seconds))

      loop do
        if cancellation&.cancelled? && !interrupted
          interrupted = true
          interrupt_process
          deadline = Time.now + 1
        end
        if deadline && Time.now >= deadline
          unless interrupted
            interrupted = true
            timed_out = true
            interrupt_process
            deadline = Time.now + 1
          else
            interrupted_protocol = {
              output: captured,
              status: 130,
              cwd: @cwd,
              input_forwarded: input_forwarded,
              timed_out: timed_out,
              truncated: truncated
            }
            raise CommandInterrupted.new(interrupted_protocol)
          end
        end

        readers = [@reader]
        readers << input if input
        readable = IO.select(readers, nil, nil, 0.02)&.first || []
        if readable.include?(@reader)
          chunk = read_chunk
          if chunk.nil?
            raise IOError, "The embedded shell exited before completing the command."
          end
          unless chunk == :wait_readable
            buffer << chunk
          end
          if chunk == :wait_readable
            next
          end
          parsed = extract_marker(buffer, marker)
          if parsed
            before, status, cwd = parsed
            captured_bytes, truncated = emit_output(
              before,
              sink,
              captured,
              captured_bytes,
              truncated,
              max_output_bytes
            )
            drain_prompt_output
            return {
              output: captured,
              status: status,
              cwd: cwd,
              input_forwarded: input_forwarded,
              timed_out: timed_out,
              truncated: truncated
            }
          end

          flush_bytes = flushable_output_bytes(buffer, marker)
          if flush_bytes.positive?
            chunk_to_emit = buffer.byteslice(0, flush_bytes)
            buffer = buffer.byteslice(flush_bytes..).to_s.b
            captured_bytes, truncated = emit_output(
              chunk_to_emit,
              sink,
              captured,
              captured_bytes,
              truncated,
              max_output_bytes
            )
          end
        end

        if input && readable.include?(input)
          input_chunk = input.read_nonblock(READ_SIZE, exception: false)
          if input_chunk.nil?
            input = nil
          elsif input_chunk != :wait_readable
            filtered = tab_action_handler&.call(input_chunk)
            input_chunk = filtered[:input].to_s if filtered
            unless input_chunk.empty?
              notify_input_forwarded(sink)
              write_raw(input_chunk)
              input_forwarded = true
            end
            if filtered && filtered[:tab_action]
              if on_detach
                detached_sink = on_detach.call
                detached = detach_protocol(
                  marker,
                  sink: detached_sink,
                  timeout_seconds: timeout_seconds,
                  max_output_bytes: max_output_bytes,
                  initial_buffer: buffer,
                  input_forwarded: input_forwarded
                )
                raise CommandInterrupted.new(
                  output: captured,
                  status: 0,
                  cwd: @cwd,
                  input_forwarded: input_forwarded,
                  tab_action: filtered[:tab_action],
                  truncated: truncated,
                  background: detached
                )
              end

              interrupt_process
              raise CommandInterrupted.new(
                output: captured,
                status: 130,
                cwd: @cwd,
                input_forwarded: input_forwarded,
                tab_action: filtered[:tab_action],
                truncated: truncated
              )
            end
          end
        end
        update_window_size
      end
    rescue Errno::EIO
      raise IOError, "The embedded shell exited before completing the command."
    end

    def detach_protocol(marker, sink:, timeout_seconds:, max_output_bytes:, initial_buffer:, input_forwarded:)
      DetachedRun.new(sink: sink, canceler: method(:interrupt_process)) do
        begin
          protocol = read_until_marker(
            marker,
            input: nil,
            sink: sink,
            timeout_seconds: timeout_seconds,
            max_output_bytes: max_output_bytes,
            cancellation: nil,
            initial_buffer: initial_buffer
          )
          update_cwd(protocol[:cwd])
          InteractiveResult.new(
            exit_status: protocol[:status] || 1,
            input_forwarded: input_forwarded || protocol[:input_forwarded],
            background: nil
          )
        ensure
          sink.finish if sink.respond_to?(:finish)
        end
      end
    end

    def extract_marker(buffer, marker)
      match = buffer.match(/#{Regexp.escape(marker)}:(-?\d+):(.*?)\r?\n/m)
      return nil unless match

      before = buffer.byteslice(0, match.begin(0)).to_s
      [before, match[1].to_i, match[2].to_s]
    end

    def flushable_output_bytes(buffer, marker)
      candidate_start = buffer.rindex(marker.getbyte(0).chr)
      if candidate_start
        candidate = buffer.byteslice(candidate_start..).to_s
        return candidate_start if marker.start_with?(candidate) || candidate.start_with?(marker)
      end

      max_prefix = [buffer.bytesize, marker.bytesize - 1].min
      suffix_length = (1..max_prefix).reverse_each.find do |length|
        buffer.end_with?(marker.byteslice(0, length))
      end || 0
      buffer.bytesize - suffix_length
    end

    def drain_prompt_output
      loop do
        readable = IO.select([@reader], nil, nil, 0.01)&.first || []
        break unless readable.include?(@reader)

        chunk = read_chunk
        break if chunk.nil? || chunk == :wait_readable
      end
    rescue IOError, Errno::EIO
      nil
    end

    def emit_output(text, sink, captured, captured_bytes, truncated, max_output_bytes)
      return [captured_bytes, truncated] if text.to_s.empty?

      if sink
        sink.write(text)
        sink.flush if sink.respond_to?(:flush)
        return [captured_bytes, truncated]
      end

      return [captured_bytes, truncated] unless max_output_bytes

      remaining = max_output_bytes - captured_bytes
      if remaining <= 0
        return [captured_bytes, true]
      end

      bytes = text.byteslice(0, remaining).to_s
      captured << bytes
      truncated ||= bytes.bytesize < text.bytesize
      [captured_bytes + bytes.bytesize, truncated]
    end

    def notify_input_forwarded(sink)
      sink.input_forwarded if sink.respond_to?(:input_forwarded)
    end

    def execute_command(command, display_command:, timeout_seconds: nil, cancellation: nil, suppress_git_pager: false, &block)
      protocol = execute_protocol(
        command,
        timeout_seconds: timeout_seconds || @timeout_seconds,
        cancellation: cancellation,
        suppress_git_pager: suppress_git_pager
      )
      output = command_echo(display_command)
      output << clean_output(protocol[:output])
      append_output_newline(output)
      status = protocol[:status] || 1
      if protocol[:timed_out]
        output << "kwsh: command timed out after #{effective_timeout(timeout_seconds)} seconds\n"
        status = 1
      elsif protocol[:truncated]
        output << "kwsh: output exceeded #{@max_output_bytes} bytes; output truncated\n"
        status = 1
      elsif cancellation&.cancelled?
        output << "^C\n" unless output.end_with?("^C\n")
        status = 130
      end
      output << "Exit status: #{status}\n" unless status.zero?
      update_cwd(protocol[:cwd])
      block&.call(output)
      Result.new(output: output, exit_status: status, streamed: block_given?)
    end

    def source_result(command, words)
      unless words.length == 2
        return Result.new(output: "#{command_echo(command)}Usage: source <file>\n", exit_status: 2)
      end

      path = Kwshrc.resolve_path(words[1], cwd: @cwd, env: @env)
      config = Kwshrc.read_file(path, env: @env)
      exports = config[:env]
      if exports.any?
        assignments = exports.map { |key, value| "#{key}=#{Shellwords.escape(value)}" }
        protocol = execute_protocol("export #{assignments.join(" ")}", timeout_seconds: STARTUP_TIMEOUT_SECONDS, max_output_bytes: nil)
        unless protocol[:status].to_i.zero?
          return Result.new(output: "#{command_echo(command)}kwsh: source: could not apply environment\n", exit_status: 1)
        end
      end

      @env.merge!(exports)
      @aliases.merge!(config[:aliases])
      @routing_shell = build_routing_shell
      @completion_shell = nil
      Result.new(output: command_echo(command), exit_status: 0)
    rescue Kwshrc::ParseError => e
      Result.new(output: "#{command_echo(command)}kwsh: source: #{e.message}\n", exit_status: 1)
    end

    def capture_result(command, expanded_command, cancellation: nil, &block)
      captured_command = expanded_command.sub(/\A\s*capture(?:\s+|\z)/, "")
      if captured_command.empty?
        return Result.new(output: "#{command_echo(command)}Usage: capture <command>\n", exit_status: 2)
      end

      execute_command(
        captured_command,
        display_command: command,
        cancellation: cancellation,
        suppress_git_pager: true,
        &block
      )
    end

    def interactive_result(command, expanded_command)
      interactive_command = expanded_command.sub(/\A\s*pty(?:\s+|\z)/, "")
      if interactive_command.empty?
        return Result.new(output: "#{command_echo(command)}Usage: pty <command>\n", exit_status: 2)
      end

      Result.new(output: command_echo(command), exit_status: 0, interactive_command: interactive_command)
    end

    def exit_result(command, words)
      if words.length > 2 || (words[1] && !words[1].match?(/\A\d+\z/))
        return Result.new(output: "#{command_echo(command)}kwsh: #{words.first}: numeric status expected\n", exit_status: 2)
      end

      Result.new(output: command_echo(command), exit_status: words[1].to_i, exit_shell: true)
    end

    def sync_runtime_state(words)
      changed = sync_runtime_aliases(words) || sync_runtime_environment(words)
      return unless changed

      @routing_shell = build_routing_shell
      @completion_shell = nil
    end

    def sync_runtime_aliases(words)
      case words.first
      when "alias"
        before = @aliases.dup
        words.drop(1).each do |assignment|
          name, value = assignment.split("=", 2)
          @aliases[name] = value.to_s if value && Kwsh.valid_alias_name?(name)
        end
        before != @aliases
      when "unalias"
        before = @aliases.dup
        if words == ["unalias", "-a"]
          @aliases.clear
        else
          words.drop(1).reject { |name| name.start_with?("-") }.each { |name| @aliases.delete(name) }
        end
        before != @aliases
      else
        false
      end
    end

    def sync_runtime_environment(words)
      before = @env.dup
      case words.first
      when "export"
        words.drop(1).reject { |assignment| assignment.start_with?("-") }.each do |assignment|
          key, value = assignment.split("=", 2)
          @env[key] = value.to_s if value && valid_environment_key?(key)
        end
      when "unset"
        words.drop(1).reject { |key| key == "--" || key.start_with?("-") }.each do |key|
          @env.delete(key) if valid_environment_key?(key)
        end
      else
        if words.all? { |word| word.match?(/\A[A-Za-z_][A-Za-z0-9_]*=.*/) }
          words.each do |assignment|
            key, value = assignment.split("=", 2)
            @env[key] = value.to_s if valid_environment_key?(key)
          end
        end
      end
      before != @env
    end

    def valid_environment_key?(key)
      key.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end

    def stateful_command?(words)
      STATEFUL_COMMANDS.include?(words.first) || words.all? { |word| word.match?(/\A[A-Za-z_][A-Za-z0-9_]*=.*/) }
    end

    def shell_words(command)
      Shellwords.shellsplit(command)
    end

    def command_echo(command)
      ANSI.sanitize_transcript("$ #{command}\n")
    end

    def clean_output(output)
      ANSI.sanitize_transcript(output.to_s.gsub("\r\n", "\n").gsub("\r", "\n"))
    end

    def append_output_newline(output)
      output << "\n" unless output.empty? || output.end_with?("\n")
    end

    def remember_result(command, result)
      @last_command = command.to_s
      @last_result = result
    end

    def update_cwd(value)
      path = value.to_s
      return if path.empty? || !File.directory?(path)

      return if path == @cwd

      @cwd = File.expand_path(path)
      @completion_shell = nil
      @routing_shell = build_routing_shell
      @env = @routing_shell.child_env
    rescue ArgumentError
      nil
    end

    def display_cwd
      home = Dir.home.to_s
      return "~" if @cwd == home
      return "~#{@cwd.delete_prefix(home)}" if !home.empty? && @cwd.start_with?("#{home}/")

      @cwd
    rescue ArgumentError
      @cwd
    end

    def context_output(output, max_output_bytes)
      text = ANSI.sanitize_transcript(output.to_s)
      limit = max_output_bytes.to_i
      return text if limit <= 0 || text.bytesize <= limit

      prefix = "[Earlier output omitted; showing the end of the command output.]\n"
      tail_limit = [limit - prefix.bytesize, 0].max
      tail = text.byteslice(-tail_limit, tail_limit).to_s if tail_limit.positive?
      value = "#{prefix}#{tail}"
      ANSI.normalize_transcript_encoding(value.byteslice(-limit, limit).to_s)
    end

    def next_marker
      @marker_counter += 1
      "#{@marker_prefix}#{@marker_counter}__"
    end

    def effective_timeout(timeout_seconds)
      timeout = timeout_seconds.to_i
      timeout.positive? ? timeout : @timeout_seconds
    end

    def write_raw(value)
      @write_mutex.synchronize do
        ensure_open
        @writer.write(value)
        @writer.flush
      end
    end

    def interrupt_process
      write_raw("\u0003")
    rescue IOError, Errno::EIO
      nil
    end

    def restart_process
      close
      @closed = false
      start_process
      initialize_protocol
    rescue StandardError
      close
      raise
    end

    def read_chunk
      chunk = @reader.read_nonblock(READ_SIZE, exception: false)
      return nil if chunk.nil?
      return :wait_readable if chunk == :wait_readable

      chunk
    end

    def update_window_size
      return unless @reader && !@reader.closed?

      rows, columns = @window_size_provider ? @window_size_provider.call : IO.console&.winsize
      rows = LocalPtyCommandRunner::DEFAULT_ROWS unless rows.to_i.positive?
      columns = LocalPtyCommandRunner::DEFAULT_COLUMNS unless columns.to_i.positive?
      size = [rows, columns]
      return if size == @window_size

      @window_size = size
      @reader.winsize = size
    rescue StandardError
      nil
    end

    def process_running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def terminate_process_group(pid)
      return unless pid

      signal_process("TERM", -pid) || signal_process("TERM", pid)
      deadline = Time.now + 0.2
      while Time.now < deadline
        return unless process_running?(pid)

        sleep 0.02
      end
      signal_process("KILL", -pid) || signal_process("KILL", pid)
    end

    def signal_process(signal, pid)
      Process.kill(signal, pid)
      true
    rescue Errno::ESRCH, Errno::EINVAL, Errno::EPERM
      false
    end

    def ensure_open
      raise IOError, "The embedded shell is closed." if @closed || !@reader || @reader.closed?
    end
  end
end
