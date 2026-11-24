require "json"
require "io/wait"

require "tmpdir"
require_relative "declarations"

module Kward
  # Extracts locations from the current buffer without executing it.
  class SourceOutline
    MAX_SOURCE_BYTES = 512 * 1024
    MAX_OUTPUT_BYTES = 1024 * 1024
    MAX_SYMBOLS = 2_000
    TIME_LIMIT = 1.5

    def symbols(path, content)
      return [] if content.bytesize > MAX_SOURCE_BYTES

      lines = content.scrub.lines
      tags = ctags_symbols(path, content, lines.length)
      return tags unless tags.nil? || tags.empty?

      SourceDeclarations.scan(lines.map { |line| line.length <= 2_000 ? line : "" }).first(MAX_SYMBOLS)
    end

    private

    def ctags_symbols(path, content, line_count)
      binary = universal_ctags
      return unless binary

      Dir.mktmpdir("kward-outline") do |directory|
        name = File.basename(path.scrub)
        unless name.match?(/\A[\w.-]+\z/) && ![".", ".."].include?(name)
          name = "buffer#{File.extname(name)[/\A\.\w+\z/]}"
        end
        snapshot = File.join(directory, name)
        File.binwrite(snapshot, content)
        output = capture(binary, "--output-format=json", "--fields=+n", "--sort=no", "-f", "-", snapshot, directory: directory)
        parse_tags(output, line_count) if output
      end
    rescue SystemCallError, IOError
      nil
    end

    def parse_tags(output, line_count)
      tags = output.scrub.lines.filter_map do |line|
        tag = JSON.parse(line)
        next unless tag.is_a?(Hash) && tag["_type"] == "tag"
        next unless tag["line"].is_a?(Integer) && tag["line"].between?(1, line_count)
        next unless tag["name"].is_a?(String) && tag["kind"].is_a?(String)

        { name: tag["name"], kind: tag["kind"], scope: tag["scope"].is_a?(String) ? tag["scope"] : nil, line: tag["line"] }
      rescue JSON::ParserError
        nil
      end
      tags.uniq.sort_by { |tag| tag[:line] }.first(MAX_SYMBOLS)
    end

    def universal_ctags
      return @universal_ctags if defined?(@universal_ctags)

      Dir.mktmpdir("kward-outline") do |directory|
        @universal_ctags = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).flat_map do |entry|
          next [] unless entry.start_with?(File::SEPARATOR)

          %w[ctags universal-ctags ctags-universal].filter_map do |name|
            binary = File.join(entry, name)
            binary if File.file?(binary) && File.executable?(binary)
          end
        end.uniq.find do |binary|
          version = capture(binary, "--version", directory: directory)
          version&.include?("Universal Ctags") && capture(binary, "--list-features", directory: directory)&.match?(/^json\s/)
        end
      end
    rescue SystemCallError, IOError
      @universal_ctags = nil
    end

    def capture(binary, *arguments, directory:)
      reader, writer = IO.pipe
      pid = Process.spawn([binary, binary], "--options=NONE", *arguments,
                          chdir: directory, in: File::NULL, out: writer, err: File::NULL, unsetenv_others: true)
      writer.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIME_LIMIT
      output = +"".b
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if remaining <= 0 || !reader.wait_readable(remaining)

        chunk = reader.read_nonblock(16_384, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable

        output << chunk
        return if output.bytesize > MAX_OUTPUT_BYTES
      end
      loop do
        if (result = Process.waitpid2(pid, Process::WNOHANG))
          pid = nil
          return output.force_encoding(Encoding::UTF_8) if result.last.success?
          return
        end
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    rescue SystemCallError, IOError
      nil
    ensure
      reader&.close
      writer&.close unless writer&.closed?
      stop_process(pid) if pid
    end

    def stop_process(pid)
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    ensure
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
