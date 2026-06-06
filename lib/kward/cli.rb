require "json"
require "tty-prompt"
require_relative "agent"
require_relative "ansi"
require_relative "client"
require_relative "compactor"
require_relative "config_files"
require_relative "events"
require_relative "image_attachments"
require_relative "model_info"
require_relative "openai_oauth"
require_relative "pan_server"
require_relative "plugin_registry"
require_relative "prompt_commands"
require_relative "rpc/server"
require_relative "session_store"
require_relative "tool_call"
require_relative "tool_registry"
require_relative "telemetry_stats"
require_relative "workspace"

module Kward
  class CLI
    STATUS_MESSAGE = "This is a totally important status message about a non-existing status. Hi ChatGPT 👋"
    RESTORED_TOOL_OUTPUT_LIMIT = 2_000
    BUILTIN_SLASH_COMMANDS = [
      { name: "exit", description: "Exit the interactive session.", argument_hint: "" },
      { name: "quit", description: "Exit the interactive session.", argument_hint: "" },
      { name: "new", description: "Start a new session.", argument_hint: "" },
      { name: "resume", description: "Resume a saved session.", argument_hint: "[path]" },
      { name: "name", description: "Name or clear the current session.", argument_hint: "[name]" },
      { name: "clone", description: "Clone the current session.", argument_hint: "" },
      { name: "export", description: "Export the current session as Markdown.", argument_hint: "[path]" },
      { name: "compact", description: "Compact the current conversation context.", argument_hint: "[instructions]" },
      { name: "redraw", description: "Refresh the visible terminal.", argument_hint: "" },
      { name: "settings", description: "Configure prompt overlays.", argument_hint: "" },
      { name: "model", description: "Select the default model.", argument_hint: "" },
      { name: "reasoning", description: "Select reasoning effort.", argument_hint: "" },
      { name: "status", description: "Show the current status message.", argument_hint: "" },
      { name: "stats", description: "Show telemetry logging stats.", argument_hint: "[range]" }
    ].freeze
    BUILTIN_SLASH_COMMAND_NAMES = BUILTIN_SLASH_COMMANDS.map { |command| command[:name] }.freeze

    def initialize(argv: ARGV, stdin: STDIN, prompt: TTY::Prompt.new, client: Client.new, session_store: nil)
      @argv = argv
      @stdin = stdin
      @prompt = prompt
      @client = client
      @session_store = session_store
      @active_session = nil
      @cleanup_sessions = []
      @plugin_registry = nil
      @color_enabled = ANSI.enabled?($stdout)
    end

    def run
      if @argv.first == "rpc" && @argv.length == 1
        Kward::RPC::Server.new(input: @stdin, output: $stdout, client: @client).run
        return
      end

      if pan_mode?
        PanServer.new(client: @client, working_directory: pan_working_directory).run
        return
      end

      if ["login", "--login"].include?(@argv.first) && @argv.length == 1
        login
        return
      end

      first_prompt = @argv.join(" ").strip
      unless first_prompt.empty?
        answer = one_shot(first_prompt)
        puts answer unless answer.empty?
        return
      end

      stdin_prompt = piped_prompt
      unless stdin_prompt.empty?
        answer = one_shot(stdin_prompt)
        puts answer unless answer.empty?
        return
      end

      interactive_loop
    end

    def one_shot(input)
      streamed = false
      assistant_streamed = false
      markdown_chunks = []
      conversation = new_conversation
      agent = Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(prompt: @prompt),
        conversation: conversation
      )
      answer = agent.ask(input) do |event|
        case event
        when Events::ReasoningDelta
          streamed = true
          append_markdown_delta(markdown_chunks, "Reasoning", event.delta)
        when Events::AssistantDelta
          streamed = true
          assistant_streamed = true
          append_markdown_delta(markdown_chunks, "Assistant", event.delta)
        when Events::Retry
          streamed = true
          flush_markdown_deltas(markdown_chunks)
          print_retry(event)
        when Events::ToolCall
          streamed = true
          flush_markdown_deltas(markdown_chunks)
          print_tool_call(event.tool_call)
        when Events::ToolResult
          streamed = true
          flush_markdown_deltas(markdown_chunks)
          print_tool_result(event.tool_call, event.content)
        end
      end
      flush_markdown_deltas(markdown_chunks) if streamed
      assistant_streamed ? "" : render_markdown_transcript(answer)
    end

    def login(oauth: OpenAIOAuth.new)
      path = oauth.login(prompt: @prompt)
      @prompt.say("#{colored("Saved", :green, :bold)} OpenAI OAuth login to #{path}")
    end

    def interactive_loop(agent: nil)
      setup_interactive_prompt
      session_store = interactive_session_store(agent)
      if session_store && agent.nil?
        @active_session = track_session(session_store.create(model: current_model_id, reasoning_effort: current_reasoning_effort))
        conversation = new_conversation(workspace_root: session_store.cwd)
        @active_session.attach(conversation)
        agent = build_interactive_agent(conversation)
      elsif session_store
        @active_session = track_session(session_store.create(model: current_model_id, reasoning_effort: current_reasoning_effort))
        @active_session.attach(agent.conversation)
      else
        agent ||= build_interactive_agent(new_conversation)
      end

      @footer_conversation = agent.conversation

      @prompt.say(colored("Ruby CLI Agent", :cyan, :bold))
      @prompt.say("Session: #{@active_session.path}") if @active_session
      help = "Ask a question and press Enter. Type /exit to quit. Use /redraw to refresh."
      help += " Use Shift+Enter for new lines." if prompt_interface?
      @prompt.say("#{help}\n")

      @pending_inputs = []

      loop do
        input = @pending_inputs.shift || @prompt.ask("You>")
        break if input.nil?

        command = input.strip
        next if command.empty?
        input = selected_slash_command_input(input) || input
        command = input.strip
        break if ["/exit", "/quit"].include?(command)
        handled, replacement_agent = handle_local_slash_command(command, agent, session_store)
        agent = replacement_agent if replacement_agent
        next if handled

        input = expand_prompt_template(input) || input
        @footer_conversation = agent.conversation
        pending_inputs = run_interactive_turn(agent, input)
        pending_inputs.reverse_each { |pending_input| @pending_inputs.unshift(pending_input) }
      end

      agent.conversation
    rescue Interrupt
      @prompt.say("\nGoodbye.")
      agent&.conversation
    ensure
      begin
        @prompt.close if prompt_interface?
      ensure
        cleanup_unused_sessions
      end
    end

    def piped_prompt
      return "" if @stdin.tty?

      @stdin.read.strip
    end

    private

    def pan_mode?
      @argv.include?("--pan-mode")
    end

    def pan_working_directory
      value = option_value("--working-directory")
      value.to_s.strip.empty? ? Dir.pwd : value
    end

    def option_value(name)
      @argv.each_with_index do |argument, index|
        return argument.split("=", 2).last if argument.start_with?("#{name}=")
        return @argv[index + 1] if argument == name
      end
      nil
    end

    def interactive_session_store(agent)
      return @session_store if @session_store
      return nil if agent

      SessionStore.new
    end

    def track_session(session)
      @cleanup_sessions << session if session
      session
    end

    def cleanup_unused_sessions
      @cleanup_sessions.reverse_each do |session|
        session.delete_if_unused if session.respond_to?(:delete_if_unused)
      end
      @cleanup_sessions.clear
    end

    def cleanup_replaced_session(previous_session)
      return unless previous_session
      return if @active_session && File.expand_path(previous_session.path) == File.expand_path(@active_session.path)

      previous_session.delete_if_unused if previous_session.respond_to?(:delete_if_unused)
    end

    def new_conversation(workspace_root: Dir.pwd)
      Conversation.new(workspace_root: workspace_root, model: current_model_id, reasoning_effort: current_reasoning_effort)
    end

    def build_interactive_agent(conversation)
      workspace = Workspace.new(root: conversation.workspace_root)
      Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(workspace: workspace, prompt: @prompt),
        conversation: conversation
      )
    end

    def handle_local_slash_command(command, agent, session_store)
      name, argument = parse_slash_command(command)
      case name
      when "status"
        print_status
        [true, nil]
      when "stats"
        print_stats(argument)
        [true, nil]
      when "redraw"
        @prompt.redraw if @prompt.respond_to?(:redraw)
        [true, nil]
      when "settings"
        configure_settings
        [true, nil]
      when "model"
        configure_model
        [true, nil]
      when "reasoning"
        configure_reasoning
        [true, nil]
      when "new"
        [true, start_new_session(session_store)]
      when "resume"
        [true, resume_session(session_store, argument)]
      when "name"
        rename_session(argument)
        [true, nil]
      when "clone"
        [true, clone_session(session_store, agent)]
      when "export"
        export_session(agent.conversation, argument)
        [true, nil]
      when "compact"
        compact_context(agent, argument)
        [true, nil]
      else
        return run_plugin_command(name, argument, agent) if plugin_command_for(name)

        [false, nil]
      end
    end

    def parse_slash_command(command)
      PromptCommands.parse(command) || [nil, ""]
    end

    def print_status
      lines = [STATUS_MESSAGE]
      if @active_session
        lines << ""
        lines << "Session: #{@active_session.name || @active_session.id}"
        lines << "File: #{@active_session.path}"
      end
      @prompt.say("\n#{colored("Assistant>", :green, :bold)} #{lines.join("\n")}\n")
    end

    def print_stats(argument)
      result = TelemetryStats.new.collect(argument)
      @prompt.say("\n#{colored("Assistant>", :green, :bold)} #{TelemetryStats.format(result)}\n")
    rescue ArgumentError => e
      message = e.message == TelemetryStats::USAGE ? e.message : "#{e.message}\n#{TelemetryStats::USAGE}"
      @prompt.say("\n#{message}\n")
    end

    def configure_settings
      unless settings_overlay_available?
        @prompt.say("\nSettings overlay is unavailable in this prompt.\n")
        return
      end

      settings = ConfigFiles.overlay_settings
      alignment = choose_overlay_setting("Overlay alignment", overlay_alignment_choices(settings), ConfigFiles::OVERLAY_ALIGNMENTS)
      return unless alignment

      settings = ConfigFiles.update_overlay_settings("alignment" => alignment)
      @prompt.update_overlay_settings(settings)

      width = choose_overlay_setting("Overlay width", overlay_width_choices(settings), ConfigFiles::OVERLAY_WIDTHS)
      return unless width

      settings = ConfigFiles.update_overlay_settings("width" => width)
      @prompt.update_overlay_settings(settings)
      @prompt.say("\nSaved overlay settings.\n")
    rescue StandardError => e
      @prompt.say("\nSettings error: #{e.message}\n")
    end

    def configure_model
      unless model_overlay_available?
        @prompt.say("\nModel overlay is unavailable in this prompt.\n")
        return
      end

      models = normalized_available_models
      choices = model_choices(models)
      selected = @prompt.select("Default model", choices, title: "Models", custom: true)
      return unless selected

      provider, model = selected_model(selected, models)
      raise "Model must be a non-empty string" if model.to_s.strip.empty?

      ConfigFiles.update_config(ModelInfo.config_key_for_provider(provider) => model)
      reload_client_config
      @prompt.say("\nSaved default model: #{provider} #{model}\n")
      @prompt.redraw if @prompt.respond_to?(:redraw)
    rescue StandardError => e
      @prompt.say("\nModel error: #{e.message}\n")
    end

    def configure_reasoning
      unless model_overlay_available?
        @prompt.say("\nReasoning overlay is unavailable in this prompt.\n")
        return
      end

      choices = ModelInfo::REASONING_EFFORT_CHOICES
      selected = @prompt.select("Reasoning effort", reasoning_choices(choices), title: "Reasoning")
      return unless selected

      effort, = choices.find { |_value, label| selected.to_s.downcase.start_with?(label.downcase) }
      raise "Reasoning effort must be low, medium, high, or extra high" unless effort

      ConfigFiles.update_config("openai_reasoning_effort" => effort)
      reload_client_config
      @prompt.say("\nSaved reasoning effort: #{effort}\n")
      @prompt.redraw if @prompt.respond_to?(:redraw)
    rescue StandardError => e
      @prompt.say("\nReasoning error: #{e.message}\n")
    end

    def model_overlay_available?
      @prompt.respond_to?(:select)
    end

    def settings_overlay_available?
      @prompt.respond_to?(:select) && @prompt.respond_to?(:update_overlay_settings)
    end

    def choose_overlay_setting(message, choices, values)
      choice = @prompt.select(message, choices, title: "Settings")
      return nil unless choice

      values.find { |value| choice.to_s.downcase.start_with?(value) }
    end

    def normalized_available_models
      current_provider = @client.respond_to?(:current_provider) ? @client.current_provider : "Codex"
      current_model = @client.respond_to?(:current_model) ? @client.current_model : nil
      current_reasoning = @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : nil
      models = @client.respond_to?(:available_models) ? Array(@client.available_models) : []
      models.map do |model|
        ModelInfo.normalize(
          model,
          current_provider: current_provider,
          current_model: current_model,
          current_reasoning_effort: current_reasoning
        )
      end
    end

    def model_choices(models)
      choices = models.map do |model|
        label = "#{model[:provider]} #{model[:id]}"
        label += " (current)" if model[:current]
        label
      end
      choices.empty? ? ["#{current_model_provider} #{current_model_id} (current)"] : choices.uniq
    end

    def selected_model(selected, models)
      text = selected.to_s.sub(/ \(current\)\z/, "").strip
      known = models.find { |model| "#{model[:provider]} #{model[:id]}" == text }
      return [known[:provider], known[:id]] if known

      provider, model = text.split(/\s+/, 2)
      if ["Codex", "OpenRouter"].include?(provider) && !model.to_s.strip.empty?
        [provider, model.strip]
      else
        [current_model_provider, text]
      end
    end

    def reasoning_choices(choices)
      current = @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort.to_s : ModelInfo::DEFAULT_REASONING_EFFORT
      choices.map do |effort, label|
        text = label.dup
        text += " (current)" if current == effort
        text
      end
    end

    def current_model_provider
      @client.respond_to?(:current_provider) ? @client.current_provider : "Codex"
    end

    def current_model_id
      @client.respond_to?(:current_model) ? @client.current_model : ModelInfo::DEFAULT_OPENAI_MODEL
    end

    def current_reasoning_effort
      @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT
    end

    def reload_client_config
      @client.reload_config if @client.respond_to?(:reload_config)
    end

    def overlay_alignment_choices(settings)
      ConfigFiles::OVERLAY_ALIGNMENTS.map do |alignment|
        label = alignment.capitalize
        label += " (current)" if settings["alignment"] == alignment
        label
      end
    end

    def overlay_width_choices(settings)
      ConfigFiles::OVERLAY_WIDTHS.map do |width|
        label = width.capitalize
        label += " (current)" if settings["width"] == width
        label
      end
    end

    def start_new_session(session_store)
      return say_sessions_unavailable unless session_store

      previous_session = @active_session
      @active_session = track_session(session_store.create)
      cleanup_replaced_session(previous_session)
      conversation = new_conversation(workspace_root: session_store.cwd)
      @active_session.attach(conversation)
      clear_prompt_transcript
      @prompt.say("\nStarted new session: #{@active_session.path}\n")
      build_interactive_agent(conversation)
    end

    def resume_session(session_store, argument)
      return say_sessions_unavailable unless session_store

      path = argument.to_s.strip
      path = select_session_path(session_store) if path.empty?
      return nil if path.to_s.empty?

      previous_session = @active_session
      @active_session, conversation = session_store.load(path, workspace: Workspace.new(root: session_store.cwd), model: current_model_id, reasoning_effort: current_reasoning_effort)
      track_session(@active_session)
      cleanup_replaced_session(previous_session)
      @prompt.say("\nResumed session: #{@active_session.path}\n")
      render_conversation_transcript(conversation)
      build_interactive_agent(conversation)
    rescue StandardError => e
      @prompt.say("\nError: #{e.message}\n")
      nil
    end

    def rename_session(argument)
      unless @active_session
        @prompt.say("\nNo active persisted session.\n")
        return
      end

      @active_session.rename(argument)
      label = @active_session.name ? "Named session: #{@active_session.name}" : "Cleared session name."
      @prompt.say("\n#{label}\n")
    end

    def clone_session(session_store, agent)
      return say_sessions_unavailable unless session_store

      previous_session = @active_session
      @active_session = track_session(session_store.create_from_conversation(agent.conversation))
      cleanup_replaced_session(previous_session)
      @prompt.say("\nCloned session: #{@active_session.path}\n")
      render_conversation_transcript(agent.conversation)
      agent
    end

    def compact_context(agent, argument)
      result = Compactor.new(
        conversation: agent.conversation,
        client: @client,
        tool_result_summarizer: lambda { |tool_call, content| tool_result_summary(tool_call, content) }
      ).compact(custom_instructions: argument)
      @prompt.say("\nCompacted context: #{result.old_message_count} messages -> #{result.new_message_count} messages.\n")
      render_transcript_block("Assistant", result.summary)
    rescue Compactor::NothingToCompact, Compactor::AlreadyCompacted, Compactor::EmptySummary => e
      @prompt.say("\n#{e.message}\n")
    rescue StandardError => e
      @prompt.say("\nCompaction error: #{e.message}\n")
    end


    def render_conversation_transcript(conversation)
      tool_calls_by_id = {}
      @prompt.say("\n#{colored("Transcript", :cyan, :bold)}\n")
      conversation.messages.each do |message|
        role = message_role(message)
        next if role == "system"

        case role
        when "user"
          print_user_transcript(message_content_text(message_content(message)))
        when "assistant"
          render_reasoning(message)
          render_assistant_message(message)
          message_tool_calls(message).each do |tool_call|
            tool_calls_by_id[tool_call_id(tool_call)] = tool_call
            render_tool_call(tool_call)
          end
        when "tool"
          render_tool_message(message, tool_calls_by_id)
        when "compactionSummary"
          render_transcript_block("Compaction summary", message_summary(message))
        else
          render_transcript_block(role.to_s.capitalize, message_content_text(message_content(message)))
        end
      end
    end

    def render_reasoning(message)
      reasoning = message_reasoning(message)
      render_transcript_block("Reasoning", reasoning) unless reasoning.empty?
    end

    def render_assistant_message(message)
      content = message_content_text(message_content(message))
      return if content.empty?

      render_transcript_block("Assistant", content)
    end

    def render_tool_message(message, tool_calls_by_id)
      tool_call = tool_calls_by_id[message_tool_call_id(message)] || synthetic_tool_call(message_name(message), message_tool_call_id(message))
      render_tool_result(tool_call, message_content(message).to_s)
    end

    def render_tool_call(tool_call)
      if prompt_interface?
        print_tool_call(tool_call)
      else
        @prompt.say("\n#{colored("Tool>", :magenta, :bold)}\n#{tool_command(tool_call)}\n")
      end
    end

    def render_tool_result(tool_call, content)
      summary = tool_result_summary(tool_call, content)
      if prompt_interface?
        print_tool_result(tool_call, content)
      else
        @prompt.say("\n#{colored("Tool output>", :cyan, :bold)}\n#{summary}\n")
      end
    end

    def render_transcript_block(label, content)
      return if content.to_s.empty?

      rendered = render_markdown_transcript(content)
      if prompt_interface?
        print_block_delta(label, rendered)
        finish_stream_block
      else
        @prompt.say("\n#{colored("#{label}>", label_color(label), :bold)}\n#{rendered}\n")
      end
    end

    def render_markdown_transcript(content)
      ANSI.markdown(content, enabled: @color_enabled)
    end

    def append_markdown_delta(chunks, label, delta)
      text = delta.to_s
      return if text.empty?

      if chunks.last&.first == label
        chunks.last[1] << text
      else
        chunks << [label, +text]
      end
    end

    def flush_markdown_deltas(chunks)
      chunks.each do |label, content|
        next if content.empty?

        print_block_delta(label, render_markdown_transcript(content))
        finish_stream_block
      end
      chunks.clear
    end

    def message_reasoning(message)
      direct = message["reasoning_summary"] || message[:reasoning_summary]
      return direct.to_s unless direct.to_s.empty?

      content = message_content(message)
      return "" unless content.is_a?(Array)

      content.filter_map do |part|
        type = part["type"] || part[:type]
        next unless ["thinking", "reasoning"].include?(type)

        part["thinking"] || part[:thinking] || part["text"] || part[:text]
      end.join("\n")
    end

    def message_content_text(content)
      case content
      when Array
        content.filter_map do |part|
          type = part["type"] || part[:type]
          if type == "text"
            part["text"] || part[:text]
          elsif type == "image"
            path = part["path"] || part[:path]
            media_type = part["media_type"] || part[:media_type] || "image"
            "[#{media_type}#{path ? ": #{path}" : ""}]"
          end
        end.join("\n")
      else
        content.to_s
      end
    end

    def synthetic_tool_call(name, id)
      {
        "id" => id || "restored_tool",
        "type" => "function",
        "function" => { "name" => name || "tool", "arguments" => "{}" }
      }
    end

    def message_role(message)
      message["role"] || message[:role]
    end

    def message_content(message)
      message["content"] || message[:content]
    end

    def message_summary(message)
      message["summary"] || message[:summary] || message_content(message)
    end

    def message_name(message)
      message["name"] || message[:name]
    end

    def message_tool_call_id(message)
      message["tool_call_id"] || message[:tool_call_id]
    end

    def message_tool_calls(message)
      value = message["tool_calls"] || message[:tool_calls]
      value.is_a?(Array) ? value : []
    end

    def tool_call_id(tool_call)
      tool_call["id"] || tool_call[:id]
    end

    def export_session(conversation, argument)
      path = export_path(argument)
      File.write(path, markdown_transcript(conversation))
      @prompt.say("\nExported session: #{path}\n")
    rescue StandardError => e
      @prompt.say("\nError: #{e.message}\n")
    end

    def say_sessions_unavailable
      @prompt.say("\nSessions are unavailable for this interactive loop.\n")
      nil
    end

    def clear_prompt_transcript
      @prompt.clear_transcript if @prompt.respond_to?(:clear_transcript)
    end

    def select_session_path(session_store)
      recent_limit = 20
      sessions = session_store.recent(limit: recent_limit + 1)
                              .reject { |session| active_empty_unnamed_session_info?(session) }
                              .first(recent_limit)
      if sessions.empty?
        @prompt.say("\nNo saved sessions found.\n")
        return nil
      end

      labels = sessions.map { |session| session_label(session) }
      if @prompt.respond_to?(:select)
        choice = @prompt.select("Session>", labels)
        return nil unless choice

        selected = sessions[labels.index(choice)]
        return selected&.path
      end

      numbered_labels = labels.each_with_index.map { |label, index| "#{index + 1}. #{label}" }
      @prompt.say("\nRecent sessions:\n#{numbered_labels.join("\n")}\n")
      answer = @prompt.ask("Session number or path>").to_s.strip
      if answer.match?(/\A\d+\z/)
        sessions[answer.to_i - 1]&.path
      else
        answer
      end
    end

    def active_empty_unnamed_session_info?(session)
      return false unless @active_session
      return false unless File.expand_path(session.path) == File.expand_path(@active_session.path)

      session.name.to_s.strip.empty? && session.message_count.to_i.zero?
    end

    def session_label(session)
      title = session.name.to_s.strip
      title = session.first_message.to_s.strip if title.empty?
      title = session.id if title.empty?
      "#{title} — #{File.basename(session.path)}"
    end

    def export_path(argument)
      explicit = argument.to_s.strip
      return File.expand_path(explicit, Dir.pwd) unless explicit.empty?

      if @active_session
        return @active_session.path.sub(/\.jsonl\z/, ".md")
      end

      File.expand_path("kward-session-#{Time.now.utc.iso8601(3).tr(':', '-')}.md", Dir.pwd)
    end

    def markdown_transcript(conversation)
      lines = ["# Kward Session", ""]
      conversation.messages.each do |message|
        role = message["role"] || message[:role]
        next if role == "system"

        lines << "## #{role.to_s.capitalize}"
        name = message["name"] || message[:name]
        lines << "Tool: `#{name}`" if role == "tool" && name
        lines << ""
        content = role == "compactionSummary" ? (message["summary"] || message[:summary]) : (message["content"] || message[:content])
        lines << markdown_content(content)
        lines << ""
      end
      lines.join("\n")
    end

    def markdown_content(content)
      case content
      when Array
        content.map do |part|
          text = part["text"] || part[:text]
          next text if text

          path = part["path"] || part[:path]
          media_type = part["media_type"] || part[:media_type] || "image"
          "[#{media_type}#{path ? ": #{path}" : ""}]"
        end.compact.join("\n")
      else
        content.to_s
      end
    end

    def setup_interactive_prompt
      return unless @stdin.tty?
      return unless @prompt.is_a?(TTY::Prompt)

      prompt_interface = load_prompt_interface
      return unless prompt_interface

      @prompt = prompt_interface.new(
        slash_commands: slash_command_entries,
        overlay_settings: ConfigFiles.overlay_settings,
        footer: prompt_footer_renderer,
        composer_status: method(:composer_status_text)
      )
      @prompt.start
    end

    def load_prompt_interface
      require_relative "prompt_interface"
      PromptInterface
    rescue LoadError => e
      raise unless missing_tty_tui_load_error?(e)

      nil
    end

    def missing_tty_tui_load_error?(error)
      ["tty-cursor", "tty-reader", "tty-screen"].include?(error.path) ||
        error.message.match?(/cannot load such file -- tty-(cursor|reader|screen)/)
    end

    def prompt_interface?
      @prompt.respond_to?(:start_stream_block) && @prompt.respond_to?(:write_delta)
    end

    def prompt_templates
      @prompt_templates ||= ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMAND_NAMES)
    end

    def plugin_registry
      @plugin_registry ||= PluginRegistry.load(reserved_commands: reserved_slash_command_names)
    end

    def plugin_commands
      plugin_registry.commands
    end

    def plugin_command_for(command)
      plugin_registry.command_for(command)
    end

    def reserved_slash_command_names
      BUILTIN_SLASH_COMMAND_NAMES + prompt_templates.map(&:command)
    end

    def slash_command_entries
      prompt_entries = prompt_templates.map do |template|
        {
          name: template.command,
          description: template.description,
          argument_hint: template.argument_hint
        }
      end
      plugin_entries = plugin_commands.map(&:entry)
      BUILTIN_SLASH_COMMANDS + prompt_entries + plugin_entries
    end

    def prompt_template_for(command)
      prompt_templates.find { |template| template.command == command }
    end

    def expand_prompt_template(input)
      PromptCommands.expand(input, templates: prompt_templates, reserved_commands: BUILTIN_SLASH_COMMAND_NAMES)
    end

    def run_plugin_command(name, argument, agent)
      command = plugin_command_for(name)
      return [false, nil] unless command

      context = plugin_context(agent.conversation, argument)
      command.handler.call(argument, context)
      [true, nil]
    rescue StandardError => e
      @prompt.say("\nPlugin command /#{name} error: #{e.message}\n")
      [true, nil]
    end

    def prompt_footer_renderer
      renderer = plugin_registry.footer_renderer
      return nil unless renderer

      lambda do
        context = plugin_context(current_footer_conversation, "")
        renderer.call(context).to_s
      rescue StandardError => e
        warn "Warning: Kward plugin footer error: #{e.message}"
        ""
      end
    end

    def composer_status_text
      provider = @client.respond_to?(:current_provider) ? @client.current_provider : "Codex"
      model = @client.respond_to?(:current_model) ? @client.current_model : ModelInfo::DEFAULT_OPENAI_MODEL
      reasoning = @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT
      reasoning = "n/a" if provider != "Codex" || reasoning.to_s.empty?
      "#{provider} #{model} · #{reasoning}"
    end

    def current_footer_conversation
      @footer_conversation || Conversation.new(system_message: nil)
    end

    def plugin_context(conversation, args)
      PluginRegistry::Context.new(
        conversation: conversation,
        args: args,
        session: @active_session,
        workspace_root: conversation.workspace_root,
        say_callback: lambda { |message| @prompt.say("\n#{message}\n") }
      )
    end

    def selected_slash_command_input(input)
      return nil if prompt_interface?
      return nil unless @prompt.respond_to?(:select)
      return nil unless input.match?(%r{\A/[^\s/]*\z})
      return nil if prompt_template_for(input.delete_prefix("/"))

      prefix = input.delete_prefix("/").downcase
      return nil if slash_command_entries.any? { |entry| entry[:name].downcase == prefix }

      matches = slash_command_entries.select { |entry| entry[:name].downcase.start_with?(prefix) }
      return nil if matches.empty?

      labels = matches.map { |entry| slash_command_label(entry) }
      choice = @prompt.select("Slash command>", labels)
      entry = matches[labels.index(choice)]
      entry ? "/#{entry[:name]}" : nil
    end

    def slash_command_label(entry)
      hint = entry[:argument_hint].to_s.empty? ? "" : " #{entry[:argument_hint]}"
      description = entry[:description].to_s.empty? ? "" : " - #{entry[:description]}"
      "/#{entry[:name]}#{hint}#{description}"
    end

    def run_interactive_turn(agent, input)
      print_user_transcript(input) if prompt_interface?
      return run_blocking_interactive_turn(agent, input) unless prompt_interface?

      queued_inputs = []
      streamed = false
      markdown_chunks = []
      answer = nil
      error = nil
      @prompt.begin_busy_input("You>") if @prompt.respond_to?(:begin_busy_input)

      worker = Thread.new do
        answer = agent.ask(input) do |event|
          case event
          when Events::ReasoningDelta
            streamed = true
            append_markdown_delta(markdown_chunks, "Reasoning", event.delta)
          when Events::AssistantDelta
            streamed = true
            append_markdown_delta(markdown_chunks, "Assistant", event.delta)
          when Events::Retry
            streamed = true
            flush_markdown_deltas(markdown_chunks)
            print_retry(event)
          when Events::ToolCall
            streamed = true
            flush_markdown_deltas(markdown_chunks)
            print_tool_call(event.tool_call)
          when Events::ToolResult
            streamed = true
            flush_markdown_deltas(markdown_chunks)
            print_tool_result(event.tool_call, event.content)
          end
        end
      rescue StandardError => e
        error = e
      end

      while worker.alive?
        collect_queued_input(queued_inputs)
        sleep 0.02
      end
      worker.join
      drain_queued_input(queued_inputs)
      raise error if error

      flush_markdown_deltas(markdown_chunks) if streamed
      @prompt.say("\n#{colored("Assistant>", :green, :bold)} #{render_markdown_transcript(answer)}\n") unless streamed || answer.to_s.empty?
      @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input)
      queued_inputs
    end

    def collect_queued_input(queued_inputs)
      return nil if @prompt.respond_to?(:modal_active?) && @prompt.modal_active?

      poll_result = @prompt.poll_input
      case poll_result
      when String
        queued_inputs << poll_result unless poll_result.strip.empty?
        @prompt.set_queued_count(queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
      when PromptInterface::EXIT_INPUT
        queued_inputs << "/exit"
        @prompt.set_queued_count(queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
      end
      poll_result
    end

    def drain_queued_input(queued_inputs)
      deadline = Time.now + 0.15
      loop do
        poll_result = collect_queued_input(queued_inputs)
        break if Time.now > deadline && poll_result.nil?

        sleep 0.01
      end
    end

    def run_blocking_interactive_turn(agent, input)
      streamed = false
      markdown_chunks = []
      answer = agent.ask(input) do |event|
        case event
        when Events::ReasoningDelta
          streamed = true
          append_markdown_delta(markdown_chunks, "Reasoning", event.delta)
        when Events::AssistantDelta
          streamed = true
          append_markdown_delta(markdown_chunks, "Assistant", event.delta)
        when Events::Retry
          streamed = true
          flush_markdown_deltas(markdown_chunks)
          print_retry(event)
        when Events::ToolCall
          streamed = true
          flush_markdown_deltas(markdown_chunks)
          print_tool_call(event.tool_call)
        when Events::ToolResult
          streamed = true
          flush_markdown_deltas(markdown_chunks)
          print_tool_result(event.tool_call, event.content)
        end
      end
      flush_markdown_deltas(markdown_chunks) if streamed
      @prompt.say("\n#{colored("Assistant>", :green, :bold)} #{render_markdown_transcript(answer)}\n") unless streamed || answer.to_s.empty?
      []
    end

    def print_user_transcript(input)
      @prompt.say("\n#{colored("You>", :blue, :bold)} #{input}\n")
      print_pasted_images(input)
    end

    def print_pasted_images(input)
      Kward::ImageAttachments.image_parts_from_text(input).each do |part|
        sequence = Kward::ImageAttachments.terminal_image_sequence(part)
        @prompt.say(sequence) if sequence
      end
    end

    def print_block_delta(label, delta)
      if prompt_interface?
        @prompt.start_stream_block(label)
        @prompt.write_delta(delta)
      else
        start_stream_block(label)
        print delta
        $stdout.flush
      end
    end

    def print_retry(event)
      message = retry_message(event)
      if prompt_interface?
        @prompt.start_stream_block("Retry")
        @prompt.write_delta("#{message}\n")
        @prompt.finish_stream_block
      else
        start_stream_block("Retry")
        puts message
        $stdout.flush
        @stream_block = nil
      end
    end

    def retry_message(event)
      provider = event.provider.to_s.empty? ? "model" : event.provider
      payload = event.request_bytes ? " with #{event.request_bytes} byte payload" : ""
      "Retrying #{provider} request after transient failure (attempt #{event.attempt}/#{event.max_attempts}) in #{event.delay_seconds}s#{payload}: #{event.error}"
    end

    def print_tool_call(tool_call)
      if prompt_interface?
        @prompt.start_stream_block("Tool")
        @prompt.write_delta("#{tool_command(tool_call)}\n")
        @prompt.finish_stream_block
      else
        start_stream_block("Tool")
        puts tool_command(tool_call)
        $stdout.flush
        @stream_block = nil
      end
    end

    def print_tool_result(tool_call, content)
      summary = tool_result_summary(tool_call, content)
      if prompt_interface?
        @prompt.start_stream_block("Tool output")
        @prompt.write_delta(summary)
        @prompt.write_delta("\n") unless summary.end_with?("\n")
        @prompt.finish_stream_block
      else
        start_stream_block("Tool output")
        print summary
        puts unless summary.end_with?("\n")
        $stdout.flush
        @stream_block = nil
      end
    end

    def tool_result_summary(tool_call, content)
      name = tool_call_name(tool_call)
      args = tool_call_args(tool_call)
      text = content.to_s
      return error_tool_summary(name, args, text) if text.start_with?("Error:", "Declined:")

      case name
      when "read_file"
        read_file_summary(args, text)
      when "write_file", "edit_file"
        file_change_summary(name, args, text)
      when "run_shell_command"
        shell_command_summary(args, text)
      when "web_research"
        web_research_summary(args, text)
      else
        generic_tool_summary(name, text)
      end
    end

    def read_file_summary(args, content)
      path = args["path"] || args[:path] || "(unknown path)"
      "read_file: #{path}\n#{content.lines.count} lines, #{content.bytesize} bytes"
    end

    def file_change_summary(name, args, content)
      path = args["path"] || args[:path] || path_from_tool_result(content) || "(unknown path)"
      concise = content.lines.first.to_s.strip
      concise = "completed" if concise.empty?
      "#{name}: #{path}\n#{concise}"
    end

    def shell_command_summary(args, content)
      command = args["command"] || args[:command] || ""
      lines = ["run_shell_command: #{command}".strip]
      lines << "Exit status: #{shell_exit_status(content) || "unknown"}"
      stdout = shell_section(content, "STDOUT")
      stderr = shell_section(content, "STDERR")
      lines << compact_stream_summary("stdout", stdout) unless stdout.empty?
      lines << compact_stream_summary("stderr", stderr) unless stderr.empty?
      lines.join("\n")
    end

    def web_research_summary(args, content)
      queries = Array(args["queries"] || args[:queries]).map(&:to_s)
      queries = web_research_queries_from_content(content) if queries.empty?
      counts = web_research_result_counts(content)
      lines = ["web_research"]
      queries.each do |query|
        lines << "#{query}: #{counts.fetch(query, 0)} result(s)"
      end
      lines << "#{web_research_total_count(content)} result(s)" if queries.empty?
      lines.join("\n")
    end

    def error_tool_summary(name, args, content)
      path = args["path"] || args[:path]
      command = args["command"] || args[:command]
      context = path || command
      [name, context, content.lines.first.to_s.strip].compact.reject(&:empty?).join("\n")
    end

    def generic_tool_summary(name, content)
      text = content.to_s
      return "#{name}: #{text}" if text.length <= RESTORED_TOOL_OUTPUT_LIMIT

      "#{name}: #{text[0, RESTORED_TOOL_OUTPUT_LIMIT]}\n...[truncated #{text.length - RESTORED_TOOL_OUTPUT_LIMIT} bytes]"
    end

    def compact_stream_summary(label, text)
      summary = text.strip
      summary = summary[0, 500] + "\n...[truncated #{summary.length - 500} chars]" if summary.length > 500
      "#{label} (#{text.bytesize} bytes):#{summary.empty? ? "" : "\n#{summary}"}"
    end

    def shell_exit_status(content)
      content.match(/^Exit status: ([^\n]+)/)&.[](1)
    end

    def shell_section(content, name)
      match = content.match(/^#{Regexp.escape(name)}:\n(.*?)(?=\nSTD(?:OUT|ERR):\n|\z)/m)
      match ? match[1] : ""
    end

    def web_research_queries_from_content(content)
      content.scan(/^## Query: (.+)$/).flatten
    end

    def web_research_result_counts(content)
      counts = {}
      current_query = nil
      content.each_line do |line|
        if (match = line.match(/^## Query: (.+)$/))
          current_query = match[1]
          counts[current_query] ||= 0
        elsif current_query && line.match?(/^\d+\. /)
          counts[current_query] += 1
        end
      end
      counts
    end

    def web_research_total_count(content)
      content.each_line.count { |line| line.match?(/^\d+\. /) }
    end

    def path_from_tool_result(content)
      content.match(/\b(?:to|file|Edited)\s+([^:\n]+?)(?:\s|:|\z)/)&.[](1)
    end

    def tool_call_name(tool_call)
      ToolCall.name(tool_call) || "unknown_tool"
    end

    def tool_call_args(tool_call)
      ToolCall.arguments(tool_call)
    end

    def start_stream_block(label)
      return if @stream_block == label

      puts if @stream_block
      puts "\n#{colored("#{label}>", label_color(label), :bold)}"
      @stream_block = label
    end

    def finish_stream_block
      if prompt_interface?
        @prompt.finish_stream_block
      else
        puts if @stream_block
        @stream_block = nil
      end
    end

    def colored(text, *styles)
      ANSI.colorize(text, *styles, enabled: @color_enabled)
    end

    def label_color(label)
      case label
      when "Reasoning"
        :yellow
      when "Assistant"
        :green
      when "Tool"
        :magenta
      when "Tool output"
        :cyan
      else
        :blue
      end
    end

    def tool_command(tool_call)
      name = tool_call_name(tool_call)
      args = tool_call_args(tool_call)

      if name == "run_shell_command"
        args["command"] || args[:command] || ""
      elsif args.empty?
        name.to_s
      else
        "#{name} #{JSON.dump(args)}"
      end
    end

  end
end
