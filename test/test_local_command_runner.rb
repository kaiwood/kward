require_relative "test_helper"

class TestLocalCommandRunner < KwardTestCase
  def test_runs_command_with_cwd_and_env
    Dir.mktmpdir do |dir|
      result = Kward::LocalCommandRunner.new(timeout_seconds: 2, max_output_bytes: 1024).run("printf '%s:%s' \"$PWD\" \"$KWARD_RUNNER_TEST\"", cwd: dir, env: { "KWARD_RUNNER_TEST" => "ok" })

      assert_equal 0, result.exit_status
      assert_equal "#{File.realpath(dir)}:ok", result.stdout
      assert_equal "", result.stderr
      refute result.timed_out
    end
  end

  def test_streams_output_chunks
    chunks = []
    runner = Kward::LocalCommandRunner.new(timeout_seconds: 2, max_output_bytes: 1024)

    result = runner.run("printf out; printf err >&2") do |stream, chunk|
      chunks << [stream, chunk]
    end

    assert_equal 0, result.exit_status
    assert_equal "out", result.stdout
    assert_equal "err", result.stderr
    assert_includes chunks, [:stdout, "out"]
    assert_includes chunks, [:stderr, "err"]
  end

  def test_times_out_and_terminates_command
    runner = Kward::LocalCommandRunner.new(timeout_seconds: 1, max_output_bytes: 1024)

    result = runner.run("ruby -e 'sleep 5'")

    assert result.timed_out
    assert_nil result.exit_status
  end

  def test_truncates_captured_output
    runner = Kward::LocalCommandRunner.new(timeout_seconds: 2, max_output_bytes: 3)

    result = runner.run("printf abcdef")

    assert result.truncated
    assert_equal "abc", result.stdout
  end
end
