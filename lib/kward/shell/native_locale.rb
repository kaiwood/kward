require "fiddle"

module Kward
  module NativeShell
    # POSIX locale objects are thread-local, never process-global setlocale.
    # Wildcard iteration stays in Pattern; libc only evaluates one bracket or
    # compares two strings, avoiding recursive libc glob backtracking.
    class Locale
      DARWIN = RUBY_PLATFORM.include?("darwin")
      CTYPE_MASK = DARWIN ? 2 : 1
      COLLATE_MASK = DARWIN ? 1 : 8
      CODESET = DARWIN ? 0 : 14
      POINTER = Fiddle::TYPE_VOIDP
      NEW = Fiddle::Function.new(Fiddle::Handle::DEFAULT["newlocale"], [Fiddle::TYPE_INT, POINTER, POINTER], POINTER)
      FREE = Fiddle::Function.new(Fiddle::Handle::DEFAULT["freelocale"], [POINTER], Fiddle::TYPE_VOID)
      USE = Fiddle::Function.new(Fiddle::Handle::DEFAULT["uselocale"], [POINTER], POINTER)
      INFO = Fiddle::Function.new(Fiddle::Handle::DEFAULT["nl_langinfo_l"], [Fiddle::TYPE_INT, POINTER], POINTER)
      MATCH = Fiddle::Function.new(Fiddle::Handle::DEFAULT["fnmatch"], [POINTER, POINTER, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      COMPARE = Fiddle::Function.new(Fiddle::Handle::DEFAULT["strcoll"], [POINTER, POINTER], Fiddle::TYPE_INT)

      attr_reader :encoding, :multichar

      def self.with(variables)
        raise ExecutionError, "native locale support requires macOS or Linux" unless DARWIN || RUBY_PLATFORM.include?("linux")
        handle = nil
        collation = "C"
        { "LC_CTYPE" => CTYPE_MASK, "LC_COLLATE" => COLLATE_MASK }.each do |category, mask|
          name = [variables["LC_ALL"], variables[category], variables["LANG"], "C"].find { |value| value && !value.empty? }
          raise ExecutionError, "NUL bytes are not allowed in locale names" if name.include?("\0")
          collation = name if category == "LC_COLLATE"
          updated = NEW.call(mask, name, handle || 0)
          raise ExecutionError, "unavailable locale: #{name}" if updated.null?
          # Darwin clones base; Linux newlocale consumes it on success.
          # https://github.com/apple-oss-distributions/Libc/blob/main/locale/xlocale.c
          FREE.call(handle) if DARWIN && handle
          handle = updated
        end
        previous = USE.call(handle)
        yield new(INFO.call(CODESET, handle).to_s, multichar: !collation.match?(/\A(?:C|POSIX)(?:[.@].*)?\z/))
      ensure
        USE.call(previous) if previous
        FREE.call(handle) if handle
      end

      def initialize(codeset, multichar: true)
        @multichar = multichar
        @encoding = Encoding.find(codeset)
        @encoding = Encoding::BINARY if @encoding == Encoding::US_ASCII
      rescue ArgumentError
        raise ExecutionError, "unsupported locale encoding: #{codeset}"
      end

      def text(value)
        value.dup.force_encoding(@encoding)
      end

      def bracket?(source, value)
        validate(source, value)
        MATCH.call(source, value, 0).zero?
      end

      def collating_element?(value)
        value.length == 1 || multichar && symbol?(value, value)
      end

      def symbol?(name, value)
        return name == value if name.length == 1
        # Never let candidate input close the bracket and introduce libc glob
        # operators. Whole-pattern wildcard iteration belongs to Pattern.
        return false if name.empty? || unsafe_symbol?(name)
        bracket?("[[.#{name}.]]", value)
      end

      def equivalent?(name, value)
        return false if name.length > 1 && unsafe_symbol?(name)
        bracket?("[[=#{name}=]]", value) ||
          symbol?(name, name) && collating_element?(value) && compare(name, value).zero?
      end

      def compare(left, right)
        validate(left, right)
        COMPARE.call(left, right)
      end

      private

      def unsafe_symbol?(name)
        ["[", "]", "\\", "*", "?"].any? { |character| name.include?(character) }
      end

      def validate(*values)
        raise ExecutionError, "NUL bytes are not supported in locale comparisons" if values.any? { |value| value.include?("\0") }
      end
    end
  end
end
