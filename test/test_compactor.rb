require_relative "test_helper"

class TestCompactor < KwardTestCase
  def test_compaction_uses_neutral_system_prompt_without_workspace_personality
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(workspace, "AGENTS.md"), "Use project rules.\n")
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "workspaces" => {
            workspace => { "system_prompt" => "Speak like a starship computer." }
          }
        }))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          conversation = Kward::Conversation.new(workspace_root: workspace)
          conversation.append_user("Continue the implementation.")
          compactor = Kward::Compactor.new(conversation: conversation, client: RecordingClient.new(["summary"]))
          messages = compactor.compaction_messages

          system_content = messages.first[:content]
          user_content = messages.last[:content]
          assert_includes conversation.messages.first[:content], "Speak like a starship computer."
          refute_includes system_content, "Speak like a starship computer."
          assert_includes system_content, "Use project rules."
          refute_includes user_content, "Speak like a starship computer."
        end
      end
    end
  end
end
