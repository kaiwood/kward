require_relative "test_helper"

class TestScratchpadRunner < KwardTestCase
  def test_ruby_result_contains_output_without_mutating_source
    source = "puts 'hello'\n"

    result = Kward::ScratchpadRunner.run(:ruby, source)

    assert_equal :ruby, result.language
    assert_equal "hello\n", result.output
    assert_equal 0, result.exit_status
    refute result.cancelled
    refute result.truncated
  end

  def test_ruby_result_captures_nonzero_exit_output
    result = Kward::ScratchpadRunner.run(:ruby, "warn 'bad'\nexit 3\n")

    assert_equal "bad\n", result.output
    assert_equal 3, result.exit_status
    refute result.cancelled
  end

  def test_runner_can_cancel_a_running_process
    cancelled = false
    result = nil
    thread = Thread.new do
      result = Kward::ScratchpadRunner.run(:ruby, "loop { sleep 1 }", cancelled: -> { cancelled })
    end

    sleep 0.1
    cancelled = true
    thread.join(3)

    refute thread.alive?, "runner did not stop after cancellation"
    assert result.cancelled
    assert_equal 130, result.exit_status
  end
end
