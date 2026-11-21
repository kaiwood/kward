module Kward
  module NativeShell
    # Bash's small programmable-completion subset used by rbenv. The callback
    # is a trusted, explicitly registered function; the draft is data only.
    module ProgrammableCompletion
      COMPLETION_TIMEOUT = 2.0
      COMPLETION_BYTES = 64 * 1024
      COMPLETION_COUNT = 256

      private

      def complete_builtin(args)
        flag, function, *commands = args
        commands.shift if commands.first == "--"
        unless flag == "-F" && function&.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) && !commands.empty? && commands.none?(&:empty?)
          raise ExecutionError, "complete: expected -F function command..."
        end
        commands.each { |command| @completion_functions[command] = function }
        0
      end

      def compgen_builtin(args, streams)
        flag, list, *rest = args
        rest.shift if rest.first == "--"
        raise ExecutionError, "compgen: expected -W wordlist [--] [prefix]" unless flag == "-W" && list && rest.size <= 1

        prefix = rest.first.to_s
        matches = Shellwords.split(list).select { |word| word.start_with?(prefix) }.uniq
        matches.each { |word| write_line(streams, word) }
        matches.empty? ? 1 : 0
      end

      def programmed_candidates(words, cancel:)
        function = @completion_functions[words.first]
        return unless @functions.key?(function)

        reader, writer = IO.pipe
        pid = Process.fork do
          Process.setsid
          reader.close
          File.open(File::NULL, "r+") do |null|
            [STDIN, STDOUT, STDERR].each { |io| io.reopen(null) }
            writer.write(completion_reply(function, words, null))
          end
          exit!(0)
        rescue StandardError, Interrupt
          exit!(1)
        end
        writer.close
        read_completion(reader, cancel).split("\0").map do |word|
          word.force_encoding(words.last.encoding)
        end
      rescue IOError, SystemCallError
        []
      ensure
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        if pid
          # Keep the pid reserved until both the worker and its ordinary child
          # processes have been signaled, including when cancellation races setsid.
          Process.kill("KILL", pid) rescue nil
          Process.kill("KILL", -pid) rescue nil
          Process.waitpid(pid) rescue nil
        end
      end

      def completion_reply(function, words, null)
        reset_child_state(job_group: Process.getpgrp)
        @process_owned = true
        @replace_process = false
        @base_streams = { 0 => null, 1 => null, 2 => null }
        @persistent_descriptors = {}
        %w[COMP_WORDS COMP_CWORD COMPREPLY].each do |name|
          @variables.delete(name)
          @arrays.delete(name)
          @readonly.delete(name)
          @exported.delete(name)
        end
        @variables["COMP_CWORD"] = (words.length - 1).to_s
        @arrays["COMP_WORDS"] = Arrays::ArrayValue.new(associative: false, values: words.each_with_index.to_h { |word, index| [index, word] })
        @arrays["COMPREPLY"] = Arrays::ArrayValue.new(associative: false, values: {})
        call_function(function, [words.first, words.last, words[-2].to_s], @base_streams)
        reply = @arrays["COMPREPLY"]
        buffer = +"".b
        count = 0
        reply&.values&.each_value do |value|
          next if value.empty? || value.include?("\0")
          break if count >= COMPLETION_COUNT || buffer.bytesize + value.bytesize + 1 > COMPLETION_BYTES

          buffer << value.b << "\0"
          count += 1
        end
        buffer
      end

      def read_completion(reader, cancel)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + COMPLETION_TIMEOUT
        buffer = +"".b
        loop do
          return "" if cancel&.call
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return "" unless remaining.positive?
          next unless IO.select([reader], nil, nil, [remaining, 0.025].min)

          chunk = reader.read_nonblock(8192, exception: false)
          return buffer if chunk.nil?
          next if chunk == :wait_readable

          buffer << chunk
          return "" if buffer.bytesize > COMPLETION_BYTES
        end
      end
    end
  end
end
