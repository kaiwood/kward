require "json"
require "tmpdir"
require "tempfile"

module Kward
  module NativeShell
    # Standalone command history. No implicit disk storage; unsafe/unavailable
    # HISTFILE paths fall back to memory without altering their permissions.
    class History
      attr_reader :entries, :next_number

      def initialize(variables, directory:)
        size = variables["HISTSIZE"]
        @size = size&.match?(/\A[0-9]+\z/) ? size.to_i : 512
        @entries = []
        @next_number = 1
        @owner = Process.pid
        path = variables["HISTFILE"]
        @path = directory.resolve(path) if path && !path.empty?
        refresh
      rescue SystemCallError, IOError, ArgumentError
        @path = nil
      end

      def paused?
        @paused == true
      end

      def paused=(paused)
        discard_pending if paused
        @paused = paused
      end

      def with_entry(text)
        return yield if paused?

        @pending = text unless text.strip.empty?
        yield
      ensure
        commit_pending
      end

      def commit_pending
        pending, @pending = @pending, nil
        add(pending) if pending
      end

      def discard_pending
        @pending = nil
      end

      def add(text)
        return if paused? || text.strip.empty?
        text = text.chomp
        saved = with_lock do
          entries = read_entries
          number = [@next_number, entries.last&.first.to_i + 1].max
          entries = (entries << [number, text]).last(@size)
          persist(entries)
          update_entries(entries, number + 1)
        end
        update_entries((@entries + [[@next_number, text]]).last(@size), @next_number + 1) unless saved
      end

      def refresh
        with_lock do
          entries = read_entries
          update_entries(entries.last(@size), entries.last&.first.to_i + 1)
        end
      end

      def select(first, last, listing:)
        raise ExecutionError, "fc: history is empty" if @entries.empty?
        first ||= listing ? "-16" : "-1"
        last ||= listing ? "-1" : first
        from = index(first, range: listing || first != last)
        to = index(last, range: listing || first != last)
        selected = @entries[[from, to].min..[from, to].max]
        from > to ? selected.reverse : selected
      end

      private

      def index(value, range:)
        index = if value.match?(/\A-[0-9]+\z/)
          @entries.length + value.to_i
        elsif value.match?(/\A\+?[0-9]+\z/)
          @entries.index { |number, _| number == value.to_i } || (value.to_i < @entries.first[0] ? -1 : @entries.length)
        else
          @entries.rindex { |_, text| text.start_with?(value) }
        end
        raise ExecutionError, "fc: history entry not found: #{value}" unless index && (range || index.between?(0, @entries.length - 1))
        index.clamp(0, @entries.length - 1)
      end

      def with_lock
        return unless @path && Process.pid == @owner

        flags = File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK
        File.open("#{@path}.lock", flags, 0600) do |lock|
          validate_file(lock)
          lock.flock(File::LOCK_EX)
          yield
        end
      rescue SystemCallError, IOError, ArgumentError, JSON::ParserError
        @path = nil
      end

      def validate_file(file)
        stat = file.stat
        return if stat.file? && stat.uid == Process.uid && stat.nlink == 1 && (stat.mode & 0777) == 0600

        raise IOError, "unsafe history file"
      end

      def read_entries
        entries = []
        File.open(@path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          validate_file(file)
          file.each_line do |line|
            entry = JSON.parse(line)
            if entry.is_a?(Array) && entry[1].is_a?(Hash) && entry[1].keys == ["bytes"] && entry[1]["bytes"].is_a?(String)
              entry[1] = entry[1]["bytes"].unpack1("m0")
            end
            unless entry.is_a?(Array) && entry.size == 2 && entry[0].is_a?(Integer) && entry[0] > entries.last&.first.to_i && entry[1].is_a?(String)
              raise ArgumentError, "invalid history"
            end
            entries << entry
          end
        end
        entries
      rescue Errno::ENOENT
        []
      end

      def persist(entries)
        Tempfile.create(".kwsh-history-", File.dirname(@path)) do |file|
          entries.each do |number, text|
            value = text.dup.force_encoding(Encoding::UTF_8)
            value = { "bytes" => [text].pack("m0") } unless value.valid_encoding?
            file.puts(JSON.generate([number, value]))
          end
          file.fsync
          File.rename(file.path, @path)
        end
      end

      def update_entries(entries, next_number)
        @entries = entries
        @next_number = [@next_number, next_number].max
      end

    end

    module HistoryCommands
      def history
        raise ExecutionError, "fc: native history is standalone-only; hosted input owns its history" if @hosted
        @history ||= History.new(@variables, directory: @directory)
      end

      def with_history_entry(text)
        return yield if @hosted
        history.with_entry(text) { yield }
      end

      private

      def fc_builtin(args, streams)
        flags = []
        editor = nil
        while args.first&.start_with?("-") && !args.first.match?(/\A-[0-9]+\z/)
          option = args.shift
          break if option == "--"
          chars = option.delete_prefix("-").chars
          until chars.empty?
            flag = chars.shift
            raise ExecutionError, "fc: unsupported option -#{flag}" unless "elnrs".include?(flag)
            flags << flag
            if flag == "e"
              editor = chars.empty? ? args.shift : chars.join
              raise ExecutionError, "fc: -e requires an editor" unless editor
              chars.clear
            end
          end
        end
        listing = flags.include?("l")
        direct = flags.include?("s")
        raise ExecutionError, "fc: incompatible options" if direct && (flags - ["s"]).any? || listing && editor || flags.include?("n") && !listing
        substitution = args.shift.split("=", 2) if direct && args.first&.include?("=")
        raise ExecutionError, "fc: too many operands" if args.length > (direct ? 1 : 2)
        selected = history.select(args[0], args[1], listing: listing)
        selected.reverse! if flags.include?("r")
        if listing
          selected.each do |number, text|
            lines = text.lines(chomp: true)
            write_line(streams, "#{flags.include?('n') ? '' : number}\t#{lines.shift}")
            lines.each { |line| write_line(streams, "\t#{line}") }
          end
          return 0
        end
        history.discard_pending
        source = selected.map(&:last).join("\n") + "\n"
        if direct
          source = source.sub(substitution[0]) { substitution[1] } if substitution
        else
          editor ||= expand_parameters(@variables.fetch("FCEDIT", ""))
          editor = "ed" if editor.empty?
          result, source = edit_history(source, editor, streams)
          return result unless result.zero?
        end
        raise ExecutionError, "fc nesting exceeds 100 levels" if @eval_depth >= 100
        @eval_depth += 1
        begin
          history.add(source)
          evaluate_program(StringIO.new(source), streams)
        ensure
          @eval_depth -= 1
        end
      end

      def edit_history(source, editor, streams)
        Dir.mktmpdir("kwsh-fc-") do |directory|
          path = File.join(directory, "command")
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.chmod(0600); file.write(source) }
          result = external([editor, path], streams)
          return [result, nil] unless result.zero?
          File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
            raise ExecutionError, "fc: editor did not leave a private regular file" unless file.stat.file? && file.stat.uid == Process.uid && file.stat.nlink == 1 && (file.stat.mode & 077) == 0
            [0, file.read]
          end
        end
      end
    end
  end
end
