require_relative "test_helper"

class TestClipboard < KwardTestCase
  class TtyOutput < StringIO
    def tty?
      true
    end
  end

  def test_copy_uses_osc52_when_output_is_tty
    output = TtyOutput.new
    clipboard = Kward::Clipboard.new(output: output, env: { "PATH" => "" })

    result = clipboard.copy("hello")

    assert result.success?
    assert_equal "osc52", result.method
    assert_equal "\e]52;c;aGVsbG8=\a", output.string
  end

  def test_copy_uses_available_platform_command_without_tty
    Dir.mktmpdir do |dir|
      command = File.join(dir, "pbcopy")
      File.write(command, "#!/bin/sh\ncat >/dev/null\n")
      File.chmod(0o755, command)
      copied = []
      runner = lambda do |argv, content|
        copied << [argv, content]
        true
      end
      clipboard = Kward::Clipboard.new(output: StringIO.new, env: { "PATH" => dir }, command_runner: runner)

      result = clipboard.copy("clean text")

      assert result.success?
      assert_equal "pbcopy", result.method
      assert_equal [[["pbcopy"], "clean text"]], copied
    end
  end

  def test_copy_fails_when_no_mechanism_available
    clipboard = Kward::Clipboard.new(output: StringIO.new, env: { "PATH" => "" })

    result = clipboard.copy("hello")

    refute result.success?
    assert_equal "no supported clipboard mechanism found", result.message
  end
end
