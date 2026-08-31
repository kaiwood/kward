require_relative "../terminal_sequences"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Streams a conservative subset of PTY output into Kward's inline terminal
  # region and permanently switches to exclusive passthrough before forwarding
  # screen-oriented or unknown terminal controls.
  class AdaptivePtyOutputSink
    MAX_SEQUENCE_BYTES = 4096
    SAFE_CONTROLS = [0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d].freeze
    TERMINAL_STRING_INTRODUCERS = [0x5d, 0x50, 0x5e, 0x5f, 0x58].freeze

    attr_reader :captured_output

    def initialize(output:, on_exclusive:, max_capture_bytes: nil)
      @output = output
      @on_exclusive = on_exclusive
      @max_capture_bytes = max_capture_bytes
      @captured_output = max_capture_bytes ? +"".b : nil
      @capture_open = true
      @truncated = false
      @mode = :inline
      @sequence = +"".b
      @synchronized_output = false
    end

    def write(chunk)
      value = chunk.to_s.b
      capture(value)
      return @output.write(value) if exclusive?

      write_inline(value)
    end

    def flush
      @output.flush if @output.respond_to?(:flush)
    end

    def finish
      switch_to_exclusive(@sequence) unless @sequence.empty? || exclusive?
      end_synchronized_output if inline?
      flush
    end

    def input_forwarded
      @capture_open = false
    end

    def inline?
      @mode == :inline
    end

    def transcript_safe?
      inline? && @sequence.empty?
    end

    def pre_input_capture_only?
      true
    end

    def truncated?
      @truncated
    end

    private

    def exclusive?
      @mode == :exclusive
    end

    def write_inline(value)
      safe_output = +"".b
      index = 0
      while index < value.bytesize
        byte = value.getbyte(index)
        if @sequence.empty?
          if byte == 0x1b
            @sequence << byte
          elsif byte >= 0x20 || SAFE_CONTROLS.include?(byte)
            safe_output << byte
          else
            flush_safe_output(safe_output)
            switch_to_exclusive(value.byteslice(index..))
            return
          end
        else
          @sequence << byte
          status = sequence_status
          if status == :safe
            track_safe_sequence(@sequence)
            safe_output << @sequence
            @sequence.clear
          elsif status == :exclusive
            flush_safe_output(safe_output)
            remainder = value.byteslice((index + 1)..).to_s.b
            switch_to_exclusive(@sequence + remainder)
            @sequence.clear
            return
          end
        end
        index += 1
      end
      flush_safe_output(safe_output)
    end

    def sequence_status
      return :exclusive if @sequence.bytesize > MAX_SEQUENCE_BYTES
      return :pending if @sequence.bytesize == 1

      second = @sequence.getbyte(1)
      return csi_status if second == "[".ord
      return :exclusive if TERMINAL_STRING_INTRODUCERS.include?(second)
      return escape_intermediate_status if second.between?(0x20, 0x2f)

      :exclusive
    end

    def csi_status
      return :pending if @sequence.bytesize == 2

      byte = @sequence.getbyte(-1)
      return safe_csi? ? :safe : :exclusive if byte.between?(0x40, 0x7e)
      return :pending if byte.between?(0x20, 0x3f)

      :exclusive
    end

    def escape_intermediate_status
      byte = @sequence.getbyte(-1)
      return :pending if byte.between?(0x20, 0x2f)

      :exclusive
    end

    def safe_csi?
      value = @sequence
      value.match?(/\A\e\[[0-9:;]*m\z/) ||
        value.match?(/\A\e\[[0-2]?K\z/) ||
        value.match?(/\A\e\[[0-9;]*[CDG`]\z/) ||
        value.match?(/\A\e\[\?25[hl]\z/) ||
        value.match?(/\A\e\[\?(?:2004|2026)[hl]\z/) ||
        value.match?(/\A\e\[[0-9;]* q\z/)
    end

    def track_safe_sequence(sequence)
      @synchronized_output = true if sequence == TerminalSequences::SYNCHRONIZED_OUTPUT_ENABLE
      @synchronized_output = false if sequence == TerminalSequences::SYNCHRONIZED_OUTPUT_DISABLE
    end

    def end_synchronized_output
      return unless @synchronized_output

      @output.write(TerminalSequences::SYNCHRONIZED_OUTPUT_DISABLE)
      @synchronized_output = false
    end

    def flush_safe_output(value)
      return if value.empty?

      @output.write(value)
      value.clear
    end

    def switch_to_exclusive(value)
      end_synchronized_output
      @on_exclusive.call
      @mode = :exclusive
      @output.write(value) unless value.empty?
    end

    def capture(value)
      return unless @captured_output && @capture_open

      remaining = @max_capture_bytes - @captured_output.bytesize
      if value.bytesize > remaining
        @captured_output << value.byteslice(0, remaining) if remaining.positive?
        @truncated = true
      else
        @captured_output << value
      end
    end
  end
end
