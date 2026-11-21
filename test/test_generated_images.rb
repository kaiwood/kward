require_relative "test_helper"

class TestGeneratedImages < KwardTestCase
  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY+0AAAAASUVORK5CYII=").freeze
  CALL = { "id" => "image_call", "type" => "function", "function" => { "name" => "generate_image", "arguments" => '{"prompt":"A teal circle"}' } }.freeze

  class IdlePrompt < Kward::PromptInterface
    private

    def read_key(nonblock:) = nil
  end

  class FakeCodex
    attr_reader :image_calls, :schemas

    def initialize(resolved_provider: "Codex", retire: nil)
      @resolved_provider = resolved_provider
      @retire = retire
      @image_calls = []
    end

    def current_provider = "Codex"

    def chat(_messages, tools:, **)
      first = @schemas.nil?
      @schemas = tools
      { "role" => "assistant", "provider" => @resolved_provider, "model" => "test", "content" => first ? "" : "Done", "tool_calls" => first ? [CALL] : [] }
    end

    def generate_codex_image(prompt, turn_id:, cancellation:)
      @image_calls << [prompt, turn_id]
      cancellation.cancel! if @retire == :cancel
      PNG
    end
  end

  def test_normal_agent_turn_calls_image_tool_and_only_publishes_metadata
    with_images do |images, root|
      client = FakeCodex.new
      agent = build_agent(client, images, root)
      events = []
      assert_equal "Done", agent.ask("Create me a random image") { |event| events << event }
      assert_includes client.schemas.map { |schema| Kward::ToolCall.name(schema) }, "generate_image"
      assert_match(/\A[\da-f-]{36}\z/, client.image_calls.fetch(0).fetch(1))
      ready = events.grep(Kward::Events::ImageReady).fetch(0)
      assert_equal PNG, images.fetch(agent.conversation, ready.image.id).last
      tool_result = events.grep(Kward::Events::ToolResult).fetch(0)
      refute_includes tool_result.content, Base64.strict_encode64(PNG)
      refute_includes tool_result.content, images.path(agent.conversation, ready.image.id)
      assert_empty Dir.children(root)
    end
  end

  def test_no_request_on_provider_fallback_and_no_preview_after_cancellation
    with_images do |images, root|
      fallback = FakeCodex.new(resolved_provider: "OpenRouter")
      agent = build_agent(fallback, images, root)
      assert_equal "Done", agent.ask("Generate an image")
      assert_empty fallback.image_calls
      refute_includes fallback.schemas.map { |schema| Kward::ToolCall.name(schema) }, "generate_image"

      client = FakeCodex.new(retire: :cancel)
      events = []
      assert_raises(Kward::Cancellation::CancelledError) do
        build_agent(client, images, root).ask("Generate an image", cancellation: Kward::Cancellation.new) { |event| events << event }
      end
      assert_empty events.grep(Kward::Events::ImageReady)
    end
  end

  def test_project_export_is_scoped_exclusive_and_discard_keeps_saved_copies
    with_images do |images, root|
      owner = Kward::Conversation.new(workspace_root: root)
      image = images.add(owner, PNG)
      assert_raises(Kward::GeneratedImages::Error) { images.fetch(owner.dup, image.id) }
      assert_raises(Kward::GeneratedImages::Error) { images.fetch(owner, image.id, offset: -1) }
      assert_raises(Kward::GeneratedImages::Error) { images.save_to_project(owner, image.id, "..") }
      File.symlink(File.dirname(root), File.join(root, "escape"))
      assert_raises(Kward::GeneratedImages::Error) { images.save_to_project(owner, image.id, "escape") }
      target = File.join(root, image.filename)
      File.write(target, "existing")
      saved = images.save_to_project(owner, image.id)
      refute_equal target, saved
      assert_equal "existing", File.read(target)
      assert_equal PNG, File.binread(saved)
      temp = images.path(owner, image.id)
      assert images.discard(owner, image.id)
      refute_path_exists temp
      assert_path_exists saved
    end
  end

  def test_overlay_completes_a_directory_and_escape_navigates_then_discards
    with_images do |images, root|
      FileUtils.mkdir_p(File.join(root, "assets art"))
      FileUtils.mkdir_p(File.join(root, "assets b"))
      File.write(File.join(root, "assets note.txt"), "not a directory")
      owner = Kward::Conversation.new(workspace_root: root)
      image = images.add(owner, PNG)
      prompt = IdlePrompt.new(input: StringIO.new, output: StringIO.new, workspace_root: root)
      prompt.instance_variable_set(:@terminal_image_protocol, false)
      prompt.offer_generated_images([{ store: images, owner: owner, image: image }])
      prompt.poll_input
      assert prompt.send(:image_viewer_active?)
      assert_includes prompt.send(:image_viewer_rows, 80).join, "Save to Downloads"
      key = ->(value) { prompt.send(:handle_key, value) }
      key.call("p")
      %W[a s s \t \t].each { |value| key.call(value) }
      assert_includes prompt.send(:image_viewer_rows, 80).join, "assets art/"
      key.call("\e")
      assert_path_exists images.path(owner, image.id)
      key.call("p")
      "assets b".each_char { |value| key.call(value) }
      key.call("\r")
      saved = File.join(root, "assets b", image.filename)
      assert_equal PNG, File.binread(saved)
      key.call("\e")
      refute prompt.send(:image_viewer_active?)
      assert_path_exists saved
      assert_raises(Kward::GeneratedImages::Error) { images.path(owner, image.id) }
    end
  end

  def test_downloads_save_keeps_the_preview_and_a_failed_project_save_does_too
    with_images do |images, root|
      downloads = File.join(File.dirname(root), "Downloads")
      Dir.mkdir(downloads)
      with_env("HOME" => File.dirname(root), "XDG_CONFIG_HOME" => File.join(root, ".config")) do
        owner = Kward::Conversation.new(workspace_root: root)
        image = images.add(owner, PNG)
        prompt = IdlePrompt.new(input: StringIO.new, output: StringIO.new, workspace_root: root)
        prompt.offer_generated_images([{ store: images, owner: owner, image: image }])
        prompt.poll_input
        key = ->(value) { prompt.send(:handle_key, value) }
        key.call("d")
        assert_equal PNG, File.binread(File.join(downloads, image.filename))
        key.call("p")
        "missing".each_char { |value| key.call(value) }
        key.call("\r")
        assert_includes strip_ansi(prompt.send(:image_viewer_rows, 100).join), "Could not save the image"
        key.call("\e")
        assert_path_exists images.path(owner, image.id)
        key.call("\e")
        refute prompt.send(:image_viewer_active?)
        assert_path_exists File.join(downloads, image.filename)
      end
    end
  end

  def test_background_image_survives_turn_history_reset_and_tab_switches
    with_images do |images, root|
      owner = Kward::Conversation.new(workspace_root: root)
      image = images.add(owner, PNG)
      event = Kward::Events::ImageReady.new(tool_call: CALL, image: image)
      prompt = IdlePrompt.new(input: StringIO.new, output: StringIO.new, workspace_root: root)
      cli = Kward::CLI.new(argv: [], prompt: prompt)
      cli.instance_variable_set(:@generated_images, images)
      tab_type = Kward::CLI::Tabs::TabRuntime
      active = tab_type.new(label: "Active", event_history: [], status: "idle")
      background = tab_type.new(label: "Background", event_history: [], status: "idle", agent: Struct.new(:conversation).new(owner))
      background.record_event(event)
      cli.instance_variable_set(:@tabs, [active, background])
      cli.instance_variable_set(:@active_tab_index, 0)
      assert_equal "Background · image", cli.send(:tab_labels).last[:name]
      cli.send(:offer_tab_images, background)
      prompt.poll_input
      refute prompt.send(:image_viewer_active?)

      # A follow-up can reset render history before the image was ever shown.
      background.event_history.clear
      assert_equal "Background · image", cli.send(:tab_labels).last[:name]

      cli.instance_variable_set(:@active_tab_index, 1)
      cli.send(:offer_tab_images, background)
      prompt.poll_input
      assert prompt.send(:image_viewer_active?)
      cli.send(:suspend_tab_images, background)
      refute prompt.send(:image_viewer_active?)
      assert_path_exists images.path(owner, image.id)
      cli.send(:offer_tab_images, background)
      prompt.poll_input
      assert prompt.send(:image_viewer_active?)
    end
  end

  def test_one_preview_store_does_not_reap_live_runs
    with_images do |first, root|
      owner = Kward::Conversation.new(workspace_root: root)
      first_image = first.add(owner, PNG)
      storage = File.join(File.dirname(root), "storage")
      stale_run = File.join(storage, "run-crashed")
      Dir.mkdir(stale_run)
      File.binwrite(File.join(stale_run, "image.png"), PNG)
      second = Kward::GeneratedImages.new(base: storage)
      begin
        second.add(owner, PNG)
        assert_path_exists first.path(owner, first_image.id)
        refute_path_exists stale_run
      ensure
        second.close
      end
    end
  end

  private

  def build_agent(client, images, root)
    registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: root), image_client: client, generated_images: images)
    conversation = Kward::Conversation.new(workspace_root: root, provider: "Codex")
    Kward::Agent.new(client: client, tool_registry: registry, conversation: conversation)
  end

  def with_images
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "project")
      Dir.mkdir(root)
      images = Kward::GeneratedImages.new(base: File.join(tmp, "storage"))
      begin
        yield images, root
      ensure
        images.close
      end
    end
  end
end
