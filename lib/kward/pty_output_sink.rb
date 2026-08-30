require "thread"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Retains output while a detached PTY command runs without terminal ownership.
  class BufferedPtyOutputSink
    attr_reader :captured_output

    def initialize(max_capture_bytes:)
      @max_capture_bytes = max_capture_bytes
      @captured_output = +"".b
      @truncated = false
      @mutex = Mutex.new
    end

    def write(chunk)
      value = chunk.to_s.b
      @mutex.synchronize do
        remaining = @max_capture_bytes - @captured_output.bytesize
        if value.bytesize > remaining
          @captured_output << value.byteslice(0, remaining) if remaining.positive?
          @truncated = true
        else
          @captured_output << value
        end
      end
    end

    def flush
      nil
    end

    def finish
      nil
    end

    def transcript_safe?
      true
    end

    def pre_input_capture_only?
      true
    end

    def truncated?
      @mutex.synchronize { @truncated }
    end
  end

  # Forwards PTY output immediately and optionally keeps a bounded byte copy.
  #
  # The runner only depends on the sink's `write` method and optional `flush`
  # method. Capture is deliberately byte-oriented so PTY chunk boundaries have
  # no effect on the retained output.
  class PassthroughPtyOutputSink
    attr_reader :captured_output

    def initialize(output:, max_capture_bytes: nil)
      @output = output
      @max_capture_bytes = max_capture_bytes
      @captured_output = max_capture_bytes ? +"".b : nil
      @truncated = false
    end

    def write(chunk)
      @output.write(chunk)
      capture(chunk)
    end

    def flush
      @output.flush if @output.respond_to?(:flush)
    end

    def truncated?
      @truncated
    end

    private

    def capture(chunk)
      return unless @captured_output

      remaining = @max_capture_bytes - @captured_output.bytesize
      if chunk.bytesize > remaining
        @captured_output << chunk.byteslice(0, remaining) if remaining.positive?
        @truncated = true
      else
        @captured_output << chunk
      end
    end
  end
end
