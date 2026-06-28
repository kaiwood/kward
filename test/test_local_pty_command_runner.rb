require_relative "test_helper"

class TestLocalPtyCommandRunner < KwardTestCase
  def test_updates_window_size_while_command_runs
    sizes = [[24, 80], [24, 120]]
    runner = Kward::LocalPtyCommandRunner.new(
      timeout_seconds: 5,
      max_output_bytes: 1024,
      window_size_provider: -> { sizes.shift || [24, 120] }
    )
    ruby = RbConfig.ruby

    result = runner.run(ruby, "-rio/console", "-e", "sleep 0.08; print IO.console.winsize[1]")

    assert_equal 0, result.exit_status
    assert_includes result.stdout, "120"
  end
end
