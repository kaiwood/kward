require "stringio"

module Kward
  module NativeShell
    # Read one complete command at a time. In stdin mode the next byte may belong
    # to read or an external command, so never buffer past the logical boundary.
    module Program
      def self.source_encoding(source)
        source = source.dup.force_encoding(Encoding::UTF_8)
        source.force_encoding(Encoding::BINARY) unless source.valid_encoding?
        source
      end
      private_class_method :source_encoding

      def self.each(input, aliases: {}, on_read: nil)
        source = +"".b
        line = 1
        loop do
          begin
            byte = input.readpartial(1)
          rescue EOFError
            yield Parser.parse(source_encoding(source), aliases: aliases, line: line) unless source.empty?
            break
          end
          on_read&.call(byte)
          source << byte
          next unless byte == "\n"
          begin
            tree = Parser.parse(source_encoding(source), aliases: aliases, line: line, eof: false)
          rescue IncompleteInput
            next
          end
          yield tree
          line += source.count("\n")
          source = +"".b
        end
      end
    end
  end
end
