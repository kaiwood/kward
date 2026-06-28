require_relative "test_helper"

class TestPromptHistory < KwardTestCase
  def test_prompt_history_persists_workspace_values
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)

        assert history.append("first prompt")
        assert history.append("second prompt")

        reloaded = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        assert_equal ["first prompt", "second prompt"], reloaded.values
      end
    end
  end

  def test_prompt_history_is_workspace_scoped
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |first_workspace|
        Dir.mktmpdir do |second_workspace|
          Kward::PromptHistory.new(config_dir: config_dir, cwd: first_workspace).append("first prompt")
          Kward::PromptHistory.new(config_dir: config_dir, cwd: second_workspace).append("second prompt")

          assert_equal ["first prompt"], Kward::PromptHistory.new(config_dir: config_dir, cwd: first_workspace).values
          assert_equal ["second prompt"], Kward::PromptHistory.new(config_dir: config_dir, cwd: second_workspace).values
        end
      end
    end
  end

  def test_prompt_history_ignores_blank_consecutive_duplicates_and_invalid_json
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)

        refute history.append("   ")
        assert history.append("same")
        refute history.append("same")
        File.open(history.path, "a") { |file| file.write("not-json\n") }

        assert_equal ["same"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace).values
      end
    end
  end

  def test_prompt_history_writes_workspace_header
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        history.append("hello")

        header = JSON.parse(File.readlines(history.path, chomp: true).first)
        assert_equal "prompt_history_header", header["type"]
        assert_equal File.realpath(workspace), header["workspace"]
        assert_equal File.basename(history.path, ".jsonl"), header["workspaceHash"]
        assert_equal "prompt", header["kind"]
        assert_equal Kward::PromptHistory::DEFAULT_LIMIT, header["limit"]
      end
    end
  end

  def test_prompt_history_separates_shell_history
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        prompt_history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        shell_history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace, kind: "shell")

        prompt_history.append("explain this project")
        shell_history.append("git status --short")

        assert_equal ["explain this project"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace).values
        assert_equal ["git status --short"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace, kind: "shell").values
        refute_equal prompt_history.path, shell_history.path
        assert_equal "shell", JSON.parse(File.readlines(shell_history.path, chomp: true).first)["kind"]
      end
    end
  end

  def test_prompt_history_preserves_entry_timestamps_when_rewriting
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        history.append("one")
        first_timestamp = jsonl_records(history.path).find { |record| record["value"] == "one" }["timestamp"]
        sleep 0.002

        history.append("two")

        records = jsonl_records(history.path)
        assert_equal first_timestamp, records.find { |record| record["value"] == "one" }["timestamp"]
        refute_equal first_timestamp, records.find { |record| record["value"] == "two" }["timestamp"]
      end
    end
  end

  def test_prompt_history_truncates_to_limit
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace, limit: 2)

        history.append("one")
        history.append("two")
        history.append("three")

        assert_equal ["two", "three"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace, limit: 2).values
      end
    end
  end

  def test_prompt_history_uses_canonical_workspace_path
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |parent|
        workspace = File.join(parent, "workspace")
        link = File.join(parent, "workspace-link")
        Dir.mkdir(workspace)
        File.symlink(workspace, link)

        Kward::PromptHistory.new(config_dir: config_dir, cwd: link).append("from symlink")

        assert_equal ["from symlink"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace).values
      rescue NotImplementedError, Errno::EACCES, Errno::EPERM
        skip "symlinks are unavailable on this filesystem"
      end
    end
  end
end
