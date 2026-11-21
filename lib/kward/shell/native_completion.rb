require_relative "native_syntax"

module Kward
  module NativeShell
    # Complete literal words without expanding the draft or executing shell code.
    class Completion
      Result = Struct.new(:range, :replacement, :candidates, keyword_init: true)
      COMMAND_BOUNDARIES = %w[; && || | & ( ) { } ;; ;&].freeze
      COMMAND_PREFIXES = %w[! if then elif else while until do].freeze
      REDIRECTIONS = %w[< > << <<- >> <> >| <& >&].freeze

      def initialize(directory:, variables:, commands:)
        @directory, @variables, @commands = directory, variables, commands
      end

      def complete(input, cursor)
        source = input[0...cursor]
        tokens = lex(source)
        current = tokens.pop if tokens.last&.value.is_a?(Word) && tokens.last.finish >= cursor
        start = current ? current.start : cursor
        raw = source[start..]
        prefix = literal_text(current) if current
        return if current && !prefix
        return unless current || source[tokens.last&.finish || 0..].match?(/\A[ \t\r]*\z/)

        prefix ||= ""
        command, redirect = command_context(tokens)
        command_position = command.nil? && !redirect
        tilde = raw.start_with?("~/")
        names = if command_position && !prefix.include?("/")
                  command_candidates(prefix)
                else
                  path_candidates(prefix, tilde: tilde, directories_only: command == "cd" && !redirect, executable: command_position)
                end
        return if names.empty?

        match = names.one? ? names.first : common_prefix(names)
        unless names.one? || match.length > prefix.length
          return Result.new(range: start...cursor, replacement: raw, candidates: names)
        end

        finish = word_end(input, current, cursor)
        replacement = candidate_text(match, tilde: tilde, command: command_position && !prefix.include?("/"))
        replacement += " " if finish == input.length && names.one? && !match.end_with?("/")
        Result.new(range: start...finish, replacement: replacement, candidates: names)
      rescue SyntaxError, ArgumentError, EncodingError, SystemCallError
        nil
      end

      private

      def lex(source)
        Lexer.new(source, eof: false).tokens
      rescue IncompleteInput => e
        # The cursor is often inside a quoted filename. Close the quote for
        # tokenization only; other incomplete syntax is not evaluated or repaired.
        quote = if e.message.end_with?("unclosed single quote")
                  "'"
                elsif e.message.end_with?("unclosed double quote")
                  '"'
                else
                  raise
                end
        Lexer.new(source + quote, eof: false).tokens
      end

      def word_end(input, current, cursor)
        return cursor unless current && cursor < input.length

        word = Lexer.new(input[current.start..], eof: false).next_token
        current.start + word.finish
      end

      def literal_text(token)
        return unless token.value.parts.all? { |part| part.kind == :literal }

        token.value.parts.map(&:text).join
      end

      def command_context(tokens)
        command = nil
        redirect = false
        tokens.each do |token|
          value = token.value
          if COMMAND_BOUNDARIES.include?(value)
            command = nil
            redirect = false
          elsif REDIRECTIONS.include?(value) || (value.is_a?(Array) && value.first == :redirect)
            redirect = true
          elsif value.is_a?(Word)
            if redirect
              redirect = false
            elsif !command && !value.assignment && !COMMAND_PREFIXES.include?(value.literal)
              command = literal_text(token) || ""
            end
          end
        end
        [command, redirect]
      end

      def command_candidates(prefix)
        return [] if prefix.empty?

        names = @commands.select { |name| candidate?(name, prefix) }
        @variables.fetch("PATH", "/usr/bin:/bin").split(File::PATH_SEPARATOR, -1).each do |entry|
          directory = @directory.resolve(entry.empty? ? "." : entry)
          Dir.each_child(directory, encoding: prefix.encoding) do |name|
            next unless candidate?(name, prefix)

            file = File.join(directory, name)
            names << name if File.file?(file) && File.executable?(file)
          end
        rescue SystemCallError
          next
        end
        names.uniq.sort
      end

      def path_candidates(prefix, tilde:, directories_only:, executable:)
        dir, slash, basename = prefix.rpartition("/")
        spelling = dir + slash
        path = if tilde
                 return [] if @variables["HOME"].to_s.empty?

                 File.join(@variables["HOME"], spelling.delete_prefix("~/"))
               else
                 spelling.empty? ? "." : spelling
               end
        directory = @directory.resolve(path)
        Dir.each_child(directory, encoding: prefix.encoding).filter_map do |name|
          next unless candidate?(name, basename)
          next if name.start_with?(".") && !basename.start_with?(".")

          file = File.join(directory, name)
          if File.directory?(file)
            "#{spelling}#{name}/"
          elsif !directories_only && (!executable || (File.file?(file) && File.executable?(file)))
            "#{spelling}#{name}"
          end
        end.sort
      end

      def candidate?(name, prefix)
        name.valid_encoding? && name.start_with?(prefix) && !name.match?(/[[:cntrl:]]/)
      end

      def candidate_text(match, tilde:, command:)
        return "~/#{Shellwords.escape(match.delete_prefix('~/'))}" if tilde && match != "~/"
        return match if tilde || (command && match.match?(/\A[A-Za-z0-9_!%,@-]+\z/))

        Shellwords.escape(match)
      end

      def common_prefix(names)
        prefix = names.first.dup
        names.drop(1).each { |name| prefix.chop! until name.start_with?(prefix) }
        prefix
      end
    end
  end
end
