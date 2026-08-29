require "open3"
require "rbconfig"
require "tempfile"
require_relative "scratchpad_languages"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Executes editor buffers and returns captured runner output.
  module ScratchpadRunner
    OUTPUT_READ_SIZE = 16 * 1024
    MAX_OUTPUT_BYTES = 1_000_000
    POLL_INTERVAL = 0.05

    DEFAULT_BINARIES = {
      ruby: -> { RbConfig.ruby },
      node: "node",
      python: -> { windows_host? ? "python" : "python3" },
      shell: -> { File.executable?("/bin/sh") ? "/bin/sh" : "sh" },
      lua: "lua",
      julia: "julia",
      elixir: "elixir",
      crystal: "crystal",
      swift: "swift",
      go: "go"
    }.freeze
    RUNNER_ARGUMENTS = {
      crystal: ["run"],
      go: ["run"]
    }.freeze

    Result = Struct.new(:language, :output, :exit_status, :duration, :command, :cancelled, :truncated, keyword_init: true)

    module_function

    def run(language, content, cancelled: nil, cwd: Dir.pwd, source_path: nil, runner_config: {})
      language = ScratchpadLanguages.normalize(language)
      runner = ScratchpadLanguages.runner(language)
      raise ArgumentError, "Scratchpad language #{language.inspect} is not runnable" unless runner

      cwd = File.expand_path(cwd.to_s.empty? ? Dir.pwd : cwd)
      binary = configured_binary(runner, runner_config, cwd)
      arguments = RUNNER_ARGUMENTS.fetch(runner, [])
      default_display_path = ScratchpadLanguages.display_path(language)
      display_path = source_path.to_s.empty? ? default_display_path : File.basename(source_path.to_s)
      extension = File.extname(display_path)
      extension = File.extname(default_display_path) if extension.empty?
      started_at = monotonic_now
      output, status, was_cancelled, truncated = capture_source(
        content,
        extension: extension,
        source_path: source_path,
        cwd: cwd,
        command: [binary, *arguments],
        cancelled: cancelled
      )
      Result.new(
        language: language,
        output: output,
        exit_status: was_cancelled ? 130 : status.exitstatus,
        duration: monotonic_now - started_at,
        command: [binary, *arguments, "<#{display_path}>"],
        cancelled: was_cancelled,
        truncated: truncated
      )
    rescue Errno::ENOENT
      raise ArgumentError, "Editor runner #{runner.inspect} binary #{binary.inspect} was not found"
    rescue Errno::EACCES
      raise ArgumentError, "Editor runner #{runner.inspect} binary #{binary.inspect} is not executable"
    end

    def capture_source(content, extension:, source_path:, cwd:, command:, cancelled: nil)
      Tempfile.create(["kward-scratchpad", extension], dir: temporary_directory(cwd, source_path)) do |file|
        file.write(content.to_s)
        file.flush
        capture_process([*command, file.path], cancelled: cancelled, chdir: cwd)
      end
    end

    def configured_binary(runner, runner_config, cwd)
      settings = runner_config.is_a?(Hash) ? (runner_config[runner.to_s] || runner_config[runner]) : nil
      configured = settings.is_a?(Hash) ? (settings["binary"] || settings[:binary]) : settings
      binary = configured.nil? ? default_binary(runner) : configured
      unless binary.is_a?(String) && !binary.strip.empty?
        raise ArgumentError, "Editor runner #{runner.inspect} binary must be a non-empty string"
      end

      binary = binary.strip
      path_like?(binary) ? File.expand_path(binary, cwd) : binary
    end

    def default_binary(runner)
      value = DEFAULT_BINARIES[runner]
      value.respond_to?(:call) ? value.call : value
    end

    def temporary_directory(cwd, source_path)
      return cwd if source_path.to_s.empty?

      directory = File.dirname(File.expand_path(source_path, cwd))
      return directory if Dir.exist?(directory) && File.writable?(directory)

      cwd
    end

    def path_like?(value)
      value.include?("/") || value.include?("\\") || value.start_with?("~")
    end

    def windows_host?
      RbConfig::CONFIG["host_os"].to_s.match?(/mswin|mingw|cygwin/i)
    end

    def capture_process(command, cancelled: nil, chdir: nil)
      options = chdir ? { chdir: chdir } : {}
      input, output, wait_thread = Open3.popen2e(*command, **options)
      input.close
      chunks = []
      output_size = 0
      was_cancelled = false

      loop do
        if !was_cancelled && cancelled&.call
          terminate_process(wait_thread.pid)
          was_cancelled = true
        end

        output_size = read_available_output(output, chunks, output_size)
        break if wait_thread.join(0)

        sleep POLL_INTERVAL
      end

      output_size = read_remaining_output(output, chunks, output_size)
      [chunks.join, wait_thread.value, was_cancelled, output_size >= MAX_OUTPUT_BYTES]
    ensure
      if wait_thread&.alive?
        terminate_process(wait_thread.pid)
        wait_thread.join
      end
      input&.close unless input&.closed?
      output&.close unless output&.closed?
    end

    def read_available_output(output, chunks, output_size)
      ready = IO.select([output], nil, nil, 0)
      return output_size unless ready

      loop do
        output_size = append_output(chunks, output.read_nonblock(OUTPUT_READ_SIZE), output_size)
      rescue IO::WaitReadable, EOFError
        break
      end
      output_size
    end

    def read_remaining_output(output, chunks, output_size)
      loop do
        output_size = append_output(chunks, output.read_nonblock(OUTPUT_READ_SIZE), output_size)
      end
    rescue IO::WaitReadable, IOError, EOFError
      output_size
    end

    def append_output(chunks, chunk, output_size)
      return output_size if output_size >= MAX_OUTPUT_BYTES

      remaining = MAX_OUTPUT_BYTES - output_size
      chunks << chunk.byteslice(0, remaining)
      output_size + [chunk.bytesize, remaining].min
    end

    def terminate_process(pid)
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
