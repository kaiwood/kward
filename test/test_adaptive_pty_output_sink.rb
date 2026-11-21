require_relative "test_helper"
require_relative "../lib/kward/pty/adaptive_output_sink"

class TestAdaptivePtyOutputSink < KwardTestCase
  class EventOutput
    attr_reader :events

    def initialize(events)
      @events = events
    end

    def write(value)
      @events << [:write, value.dup]
      value.bytesize
    end

    def flush
      @events << [:flush]
    end
  end

  def build_sink(max_capture_bytes: 1024)
    events = []
    sink = Kward::AdaptivePtyOutputSink.new(
      output: EventOutput.new(events),
      on_exclusive: -> { events << [:exclusive] },
      max_capture_bytes: max_capture_bytes
    )
    [sink, events]
  end

  def written_output(events)
    events.filter_map { |event, value| value if event == :write }.join
  end

  def test_forwards_line_and_progress_output_inline
    sink, events = build_sink
    output = "Uploading 10%\r\e[2K\e[1GUploading 100%\e[32m done\e[0m\r\n"

    sink.write(output)
    sink.finish

    assert sink.inline?
    assert sink.transcript_safe?
    assert_equal output, written_output(events)
    refute_includes events, [:exclusive]
  end

  def test_forwards_utf8_output_without_treating_continuation_bytes_as_controls
    sink, events = build_sink
    output = "café 🚀\r\n"

    sink.write(output.byteslice(0, 7))
    sink.write(output.byteslice(7..))

    assert sink.inline?
    assert_equal output, written_output(events).force_encoding(Encoding::UTF_8)
  end

  def test_split_alternate_screen_sequence_switches_before_forwarding_it
    sink, events = build_sink

    sink.write("prelude\r\n\e[?10")
    assert_equal "prelude\r\n", written_output(events)

    sink.write("49hfull screen")

    assert_equal [:exclusive], events[1]
    assert_equal "prelude\r\n\e[?1049hfull screen", written_output(events)
    refute sink.inline?
    refute sink.transcript_safe?
  end

  def test_unknown_csi_switches_to_exclusive_passthrough_without_losing_bytes
    sink, events = build_sink
    output = "before\e[2Jafter\e[?1049h"

    sink.write(output)

    assert_equal output, written_output(events)
    assert_equal 1, events.count { |event| event == [:exclusive] }
    refute sink.inline?
  end

  def test_kitty_probe_and_chunked_image_stay_inline_without_replaying_payloads
    sink, events = build_sink
    probe = Kward::TerminalImageSupport::KITTY_PROBE
    image = Kward::TerminalSequences.kitty_graphics("A" * 4100, image_id: 7)
    output = "before\r\n#{probe}#{image}after\r\n"
    output.each_byte { |byte| sink.write(byte.chr) }
    sink.finish

    assert sink.inline?
    assert sink.transcript_safe?
    assert sink.preserve_terminal_view?
    assert_equal output, written_output(events)
    assert_equal "before\r\n\e[cafter\r\n", sink.captured_output
    refute sink.truncated?
  end

  def test_unknown_or_incomplete_apc_still_uses_exclusive_passthrough
    ["\e_other;AAAA\e\\", "\e_Ga=q;AAAA", "\e_Ga=q;AA\e[2J"].each do |output|
      sink, events = build_sink
      sink.write(output)
      sink.finish

      assert_equal output, written_output(events)
      refute sink.transcript_safe?
      refute sink.preserve_terminal_view?
    end
  end

  def test_later_screen_control_disables_kitty_view_preservation
    sink, events = build_sink
    output = Kward::TerminalSequences.kitty_query + "\e[?1049h"
    sink.write(output)
    sink.finish

    assert_equal output, written_output(events)
    refute sink.inline?
    refute sink.preserve_terminal_view?
  end

  def test_bracketed_paste_and_cursor_visibility_remain_inline
    sink, events = build_sink
    output = "\e[?2004h\e[?25linput\e[?25h\e[?2004l"

    sink.write(output)

    assert sink.inline?
    assert_equal output, written_output(events)
  end

  def test_synchronized_output_mode_remains_inline
    sink, events = build_sink
    output = "\e[?2026hDownloading 100%\r\e[2Kdone\e[?2026l"

    sink.write(output)
    sink.finish

    assert sink.inline?
    assert sink.transcript_safe?
    assert_equal output, written_output(events)
    refute_includes events, [:exclusive]
  end

  def test_finish_closes_unbalanced_synchronized_output
    sink, events = build_sink
    output = "\e[?2026hDownloading 100%"

    sink.write(output)
    sink.finish

    assert sink.inline?
    assert_equal output + Kward::TerminalSequences::SYNCHRONIZED_OUTPUT_DISABLE, written_output(events)
  end

  def test_exclusive_transition_closes_synchronized_output_before_handoff
    sink, events = build_sink
    synchronized_output = "\e[?2026hframe"
    alternate_screen = "\e[?1049hfull screen"

    sink.write(synchronized_output)
    sink.write(alternate_screen)

    assert_equal [
      [:write, synchronized_output],
      [:write, Kward::TerminalSequences::SYNCHRONIZED_OUTPUT_DISABLE],
      [:exclusive],
      [:write, alternate_screen]
    ], events
  end

  def test_stops_retention_before_forwarded_input_can_be_echoed
    sink, events = build_sink

    sink.write("Enter OTP: ")
    sink.input_forwarded
    sink.write("123456\r\nPushed successfully\r\n")

    assert_equal "Enter OTP: ", sink.captured_output
    assert_equal "Enter OTP: 123456\r\nPushed successfully\r\n", written_output(events)
    assert sink.inline?
  end

  def test_incomplete_sequence_switches_to_exclusive_on_finish
    sink, events = build_sink

    sink.write("before\e[")
    sink.finish

    assert_equal "before\e[", written_output(events)
    assert_equal 1, events.count { |event| event == [:exclusive] }
    refute sink.transcript_safe?
  end

  def test_capture_remains_bounded_without_interrupting_output
    sink, events = build_sink(max_capture_bytes: 4)

    sink.write("abcdefgh")

    assert_equal "abcd", sink.captured_output
    assert sink.truncated?
    assert_equal "abcdefgh", written_output(events)
  end
end
