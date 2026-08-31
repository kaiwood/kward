require "shellwords"
require_relative "kwsh"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Parses the declarative subset of a shell startup file used by kwsh.
  #
  # Only aliases, exports, and source directives are handled. Other shell
  # syntax is intentionally ignored until kwsh supports scripting.
  class Kwshrc
    VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    VARIABLE_PATTERN = /[A-Za-z_][A-Za-z0-9_]*/

    class ParseError < StandardError
    end

    def self.read(paths, env: ENV.to_h)
      new(env: env).read(paths)
    end

    def self.read_file(path, env: ENV.to_h)
      parser = new(env: env)
      parser.read_path(path)
    end

    def self.resolve_path(path, cwd:, env: ENV.to_h)
      parser = new(env: env)
      expanded = parser.send(:expand_variables, path.to_s)
      expanded = expanded.sub(/\A~(?=\/|\z)/, Dir.home)
      File.expand_path(expanded, cwd)
    end

    def initialize(env: ENV.to_h)
      @environment = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @exports = {}
      @aliases = {}
      @loading = []
    end

    def read(paths)
      Array(paths).each { |path| read_file(path, required: false) }
      configuration
    end

    def read_path(path)
      read_file(path, required: true)
      configuration
    end

    private

    def configuration
      { env: @exports, aliases: @aliases }
    end

    def read_file(path, required:)
      path = File.expand_path(path.to_s)
      unless File.file?(path)
        raise ParseError, "#{path}: file not found" if required
        return
      end
      raise ParseError, "#{path}: recursive source" if @loading.include?(path)

      @loading << path
      File.foreach(path).with_index(1) do |line, line_number|
        parse_line(strip_comment(line).strip, path, line_number)
      end
    rescue Errno::EACCES, Errno::EISDIR, Errno::ENOENT => e
      raise ParseError, "#{path}: #{e.message}"
    ensure
      @loading.delete(path)
    end

    def parse_line(line, path, line_number)
      return if line.empty?

      words = Shellwords.split(line)
      return if words.empty?

      case words.shift
      when "alias"
        parse_aliases(words)
      when "export"
        parse_exports(expand_variables(line), path, line_number)
      when "source", "."
        parse_source(expand_variables(line), path, line_number)
      end
    rescue ArgumentError => e
      raise ParseError, "#{path}:#{line_number}: #{e.message}"
    end

    def parse_aliases(words)
      words.each do |assignment|
        name, command = assignment.split("=", 2)
        next unless command && Kwsh.valid_alias_name?(name)
        next if command.empty?

        @aliases[name] = command
      end
    end

    def parse_exports(line, path, line_number)
      words = Shellwords.split(line)
      assignments = words.drop(1)
      raise ParseError, "#{path}:#{line_number}: export requires a variable" if assignments.empty?

      assignments.each do |assignment|
        name, value = assignment.split("=", 2)
        next unless name.match?(VARIABLE_NAME)

        value = @environment[name] if value.nil? && @environment.key?(name)
        next if value.nil?

        @environment[name] = value
        @exports[name] = value
      end
    rescue ArgumentError => e
      raise ParseError, "#{path}:#{line_number}: #{e.message}"
    end

    def parse_source(line, path, line_number)
      words = Shellwords.split(line)
      source_path = words[1]
      if words.length != 2 || source_path.to_s.empty?
        raise ParseError, "#{path}:#{line_number}: source requires one file"
      end

      source_path = File.expand_path(source_path, File.dirname(path))
      read_file(source_path, required: true)
    rescue ArgumentError => e
      raise ParseError, "#{path}:#{line_number}: #{e.message}"
    end

    def strip_comment(line)
      result = +""
      quote = nil
      escaped = false

      line.each_char do |character|
        if escaped
          result << character
          escaped = false
        elsif character == "\\" && quote != "'"
          result << character
          escaped = true
        elsif quote
          result << character
          quote = nil if character == quote
        elsif character == "'" || character == '"'
          result << character
          quote = character
        elsif character == "#"
          break
        else
          result << character
        end
      end
      result
    end

    def expand_variables(text)
      result = +""
      quote = nil
      escaped = false
      index = 0

      while index < text.length
        character = text[index]
        if escaped
          result << character
          escaped = false
          index += 1
          next
        end
        if character == "\\" && quote != "'"
          result << character
          escaped = true
          index += 1
          next
        end
        if character == "'"
          quote = if quote == "'"
            nil
          elsif quote.nil?
            character
          else
            quote
          end
          result << character
          index += 1
          next
        end
        if character == '"'
          quote = if quote == '"'
            nil
          elsif quote.nil?
            character
          else
            quote
          end
          result << character
          index += 1
          next
        end

        if character == "$" && quote != "'"
          name, length = variable_at(text, index)
          if name
            result << @environment.fetch(name, "")
            index += length
            next
          end
        end

        result << character
        index += 1
      end
      result
    end

    def variable_at(text, index)
      if text[index + 1] == "{"
        closing = text.index("}", index + 2)
        name = text[(index + 2)...closing] if closing
        return [name, closing - index + 1] if name&.match?(VARIABLE_NAME)
      else
        match = text[(index + 1)..].match(/\A#{VARIABLE_PATTERN}/)
        return [match[0], match[0].length + 1] if match
      end
      nil
    end
  end
end
