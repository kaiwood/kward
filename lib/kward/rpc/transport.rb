require "json"

module Kward
  module RPC
    class Transport
      def initialize(input:, output:)
        @input = input
        @output = output
        @write_mutex = Mutex.new
      end

      def read_message
        headers = read_headers
        return nil unless headers

        length = headers["content-length"].to_i
        raise "Missing Content-Length header" if length <= 0

        body = @input.read(length)
        raise "Unexpected EOF while reading JSON-RPC body" unless body && body.bytesize == length

        JSON.parse(body)
      end

      def write_message(message)
        body = JSON.generate(message)
        @write_mutex.synchronize do
          @output.write("Content-Length: #{body.bytesize}\r\n\r\n")
          @output.write(body)
          @output.flush if @output.respond_to?(:flush)
        end
      end

      private

      def read_headers
        headers = {}
        saw_header = false

        loop do
          line = @input.gets
          return nil unless line

          line = line.delete_suffix("\n").delete_suffix("\r")
          break if line.empty?

          saw_header = true
          name, value = line.split(":", 2)
          raise "Invalid JSON-RPC header: #{line}" unless name && value

          headers[name.downcase] = value.strip
        end

        saw_header ? headers : nil
      end
    end
  end
end
