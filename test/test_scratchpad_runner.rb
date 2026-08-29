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

  def test_configured_node_binary_runs_javascript_and_typescript_buffers
    config = { "node" => { "binary" => RbConfig.ruby } }

    javascript = Kward::ScratchpadRunner.run(:javascript, "puts 'javascript'\n", runner_config: config)
    typescript = Kward::ScratchpadRunner.run(:typescript, "puts 'typescript'\n", runner_config: config)

    assert_equal "javascript\n", javascript.output
    assert_equal [RbConfig.ruby, "<scratchpad.js>"], javascript.command
    assert_equal "typescript\n", typescript.output
    assert_equal [RbConfig.ruby, "<scratchpad.ts>"], typescript.command
  end

  def test_configured_relative_binary_is_resolved_from_workspace
    Dir.mktmpdir do |dir|
      binary = File.join(dir, "fake-node")
      File.write(binary, "#!/usr/bin/env ruby\nputs File.extname(ARGV.last)\n")
      File.chmod(0o755, binary)

      result = Kward::ScratchpadRunner.run(
        :javascript,
        "console.log('hello')\n",
        cwd: dir,
        runner_config: { "node" => { "binary" => "./fake-node" } }
      )

      assert_equal ".js\n", result.output
      assert_equal [binary, "<scratchpad.js>"], result.command
    end
  end

  def test_toolchain_runner_arguments_are_inserted_before_source
    Dir.mktmpdir do |dir|
      binary = File.join(dir, "fake-go")
      File.write(binary, "#!/usr/bin/env ruby\nputs ARGV.first\nputs File.extname(ARGV.last)\n")
      File.chmod(0o755, binary)

      result = Kward::ScratchpadRunner.run(
        :go,
        "package main\n",
        cwd: dir,
        runner_config: { "go" => { "binary" => binary } }
      )

      assert_equal "run\n.go\n", result.output
      assert_equal [binary, "run", "<scratchpad.go>"], result.command
    end
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
