require_relative "test_helper"
require_relative "../lib/kward/skills/capture"

class TestSkillCapture < KwardTestCase
  def test_generates_a_personal_skill_draft_from_the_complete_active_branch
    Dir.mktmpdir do |config_dir|
      store, session = saved_session(config_dir)
      client = RecordingClient.new([skill_document("release-checklist", "Prepare a release.", "Run the release checks.")])
      capture = Kward::Skills::Capture.new(session_store: store, client: client, config_dir: config_dir)

      draft = capture.generate(session.path)

      assert_equal "release-checklist", draft.name
      assert_equal "Prepare a release.", draft.description
      assert_equal session.path, draft.source_path
      source = client.seen_messages.last.last[:content]
      assert_includes source, "system instructions"
      assert_includes source, "run focused tests"
      assert_includes source, "raw tool output"
    end
  end

  def test_rejects_a_session_that_does_not_fit_the_active_model_context
    Dir.mktmpdir do |config_dir|
      store, session = saved_session(config_dir)
      client = RecordingClient.new([skill_document("unused", "Unused.", "Unused.")])
      client.context_window = 100
      capture = Kward::Skills::Capture.new(session_store: store, client: client, config_dir: config_dir)

      error = assert_raises(Kward::Skills::Capture::SourceTooLargeError) { capture.generate(session.path) }

      assert_includes error.message, "only 0 are available"
      assert_empty client.seen_messages
    end
  end

  def test_saves_only_valid_reviewed_personal_skills_and_requires_explicit_overwrite
    Dir.mktmpdir do |config_dir|
      store, = saved_session(config_dir)
      capture = Kward::Skills::Capture.new(session_store: store, client: RecordingClient.new([]), config_dir: config_dir)
      original = skill_document("release-checklist", "Prepare a release.", "Run the release checks.")
      replacement = skill_document("release-checklist", "Prepare a release.", "Review the changelog.")

      saved = capture.save(original)
      assert_equal "release-checklist", saved.name
      assert_equal original, File.read(capture.skill_path("release-checklist"))
      assert_equal 0o600, File.stat(capture.skill_path("release-checklist")).mode & 0o777

      assert_raises(Kward::Skills::Capture::ConflictError) { capture.save(replacement) }
      capture.save(replacement, overwrite: true)

      assert_equal replacement, File.read(capture.skill_path("release-checklist"))
      assert_raises(Kward::Skills::Capture::InvalidDraftError) { capture.save("not a skill") }
    end
  end

  private

  def saved_session(config_dir)
    store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
    session = store.create
    conversation = Kward::Conversation.new(system_message: { role: "system", content: "system instructions" })
    session.attach(conversation)
    conversation.append_user("Please prepare the release.")
    conversation.append_assistant("I will run focused tests.")
    conversation.append_tool(tool_call_id: "call_1", name: "run_shell_command", content: "raw tool output")
    [store, session]
  end

  def skill_document(name, description, body)
    "---\nname: #{name}\ndescription: #{description}\n---\n#{body}\n"
  end
end
