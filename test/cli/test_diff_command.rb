require_relative "../test_helper"

class TestCLIDiffCommand < KwardTestCase
  class DiffPrompt < FakePrompt
    attr_reader :opened_diff

    def initialize
      super(["/diff", "/exit"])
      @opened_diff = nil
    end

    def begin_busy_input(_message, activity: "streaming")
    end

    def finish_busy_input
    end

    def poll_input
      @inputs.shift
    end

    def open_modal_diff_viewer(path, content)
      @opened_diff = { path: path, content: content, modal: true }
      true
    end

    def close
    end
  end

  def test_diff_slash_command_opens_recorded_session_diffs
    Dir.mktmpdir do |dir|
      session_store = Kward::SessionStore.new(config_dir: File.join(dir, ".kward"), cwd: dir)
      session = session_store.create
      session_store.append_record(session.path, {
        type: "tool_execution_end",
        isError: false,
        result: {
          isError: false,
          diff: "--- file.txt\n+++ file.txt\n-old\n+new\n"
        }
      })
      prompt = DiffPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: session_store)
      cli.instance_variable_set(:@active_session, session)

      cli.send(:open_session_diff)

      assert_equal true, prompt.opened_diff[:modal]
      assert_equal "Session diff", prompt.opened_diff[:path]
      assert_includes prompt.opened_diff[:content], "--- file.txt"
      assert_includes prompt.opened_diff[:content], "+new"
    end
  end
end
