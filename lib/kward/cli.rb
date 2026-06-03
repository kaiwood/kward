require "json"
require "tty-prompt"
require_relative "agent"
require_relative "ansi"
require_relative "client"
require_relative "config_files"
require_relative "events"
require_relative "image_attachments"
require_relative "openai_oauth"
require_relative "session_store"
require_relative "tool_registry"
require_relative "workspace"

module Kward
  class CLI
    STATUS_MESSAGE = "This is a totally important status message about a non-existing status. Hi ChatGPT 👋"
    RESTORED_TOOL_OUTPUT_LIMIT = 2_000
    BUILTIN_SLASH_COMMANDS = [
      { name: "exit", description: "Exit the interactive session.", argument_hint: "" },
      { name: "new", description: "Start a new session.", argument_hint: "" },
      { name: "resume", description: "Resume a saved session.", argument_hint: "[path]" },
      { name: "name", description: "Name or clear the current session.", argument_hint: "[name]" },
      { name: "clone", description: "Clone the current session.", argument_hint: "" },
      { name: "export", description: "Export the current session as Markdown.", argument_hint: "[path]" },
      { name: "redraw", description: "Refresh the visible terminal.", argument_hint: "" },
      { name: "status", description: "Show the current status message.", argument_hint: "" }
    ].freeze

    def initialize(argv: ARGV, stdin: STDIN, prompt: TTY::Prompt.new, client: Client.new, session_store: nil)
      @argv = argv
      @stdin = stdin
      @prompt = prompt
      @client = client
      @session_store = session_store
      @active_session = nil
      @color_enabled = ANSI.enabled?($stdout)
    end

    def run
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
      message = chat(
        Conversation.new.tap { |conversation| conversation.append_user(input) }.messages,
        tools: ToolRegistry.new.schemas,
        on_reasoning_delta: lambda do |delta|
          streamed = true
          print_block_delta("Reasoning", delta)
        end,
        on_assistant_delta: lambda do |delta|
          streamed = true
          print_block_delta("Assistant", delta)
        end
      )
      finish_stream_block if streamed
      streamed ? "" : message.fetch("content", "")
    end

    def login(oauth: OpenAIOAuth.new)
      path = oauth.login(prompt: @prompt)
      @prompt.say("#{colored("Saved", :green, :bold)} OpenAI OAuth login to #{path}")
    end

    def interactive_loop(agent: nil)
      setup_interactive_prompt
      session_store = interactive_session_store(agent)
      if session_store && agent.nil?
        @active_session = session_store.create
        conversation = Conversation.new
        @active_session.attach(conversation)
        agent = build_interactive_agent(conversation)
      elsif session_store
        @active_session = session_store.create
        @active_session.attach(agent.conversation)
      else
        agent ||= build_interactive_agent(Conversation.new)
      end

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
        break if command == "/exit"
        handled, replacement_agent = handle_local_slash_command(command, agent, session_store)
        agent = replacement_agent if replacement_agent
        next if handled

        input = expand_prompt_template(input) || input
        pending_inputs = run_interactive_turn(agent, input)
        pending_inputs.reverse_each { |pending_input| @pending_inputs.unshift(pending_input) }
      end

      agent.conversation
    rescue Interrupt
      @prompt.say("\nGoodbye.")
      agent&.conversation
    ensure
      @prompt.close if prompt_interface?
    end

    def piped_prompt
      return "" if @stdin.tty?

      @stdin.read.strip
    end

    private

    def interactive_session_store(agent)
      return @session_store if @session_store
      return nil if agent

      SessionStore.new
    end

    def build_interactive_agent(conversation)
      Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(workspace: Workspace.new, prompt: @prompt),
        conversation: conversation
      )
    end

    def handle_local_slash_command(command, agent, session_store)
      name, argument = parse_slash_command(command)
      case name
      when "status"
        print_status
        [true, nil]
      when "redraw"
        @prompt.redraw if @prompt.respond_to?(:redraw)
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
      else
        [false, nil]
      end
    end

    def parse_slash_command(command)
      match = command.match(%r{\A/([^\s/]+)(?:\s+(.*))?\z}m)
      return [nil, ""] unless match

      [match[1], match[2].to_s]
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

    def start_new_session(session_store)
      return say_sessions_unavailable unless session_store

      @active_session = session_store.create
      conversation = Conversation.new
      @active_session.attach(conversation)
      @prompt.say("\nStarted new session: #{@active_session.path}\n")
      build_interactive_agent(conversation)
    end

    def resume_session(session_store, argument)
      return say_sessions_unavailable unless session_store

      path = argument.to_s.strip
      path = select_session_path(session_store) if path.empty?
      return nil if path.to_s.empty?

      @active_session, conversation = session_store.load(path, workspace: Workspace.new)
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

      @active_session = session_store.create_from_conversation(agent.conversation)
      @prompt.say("\nCloned session: #{@active_session.path}\n")
      render_conversation_transcript(agent.conversation)
      agent
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

      if prompt_interface?
        print_block_delta(label, content)
        finish_stream_block
      else
        @prompt.say("\n#{colored("#{label}>", label_color(label), :bold)}\n#{content}\n")
      end
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

    def select_session_path(session_store)
      active_path = @active_session&.path
      sessions = session_store.recent.reject { |session| active_path && File.expand_path(session.path) == File.expand_path(active_path) }
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
        lines << markdown_content(message["content"] || message[:content])
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

      @prompt = prompt_interface.new(slash_commands: slash_command_entries)
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
      @prompt_templates ||= ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMANDS.map { |command| command[:name] })
    end

    def slash_command_entries
      prompt_entries = prompt_templates.map do |template|
        {
          name: template.command,
          description: template.description,
          argument_hint: template.argument_hint
        }
      end
      BUILTIN_SLASH_COMMANDS + prompt_entries
    end

    def prompt_template_for(command)
      prompt_templates.find { |template| template.command == command }
    end

    def expand_prompt_template(input)
      match = input.match(%r{\A/([^\s/]+)(?:\s+(.*))?\z}m)
      return nil unless match

      template = prompt_template_for(match[1])
      return nil unless template

      template.expand(match[2].to_s)
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
      answer = nil
      error = nil
      @prompt.begin_busy_input("You>") if @prompt.respond_to?(:begin_busy_input)

      worker = Thread.new do
        answer = agent.ask(input) do |event|
          case event
          when Events::ReasoningDelta
            streamed = true
            print_block_delta("Reasoning", event.delta)
          when Events::AssistantDelta
            streamed = true
            print_block_delta("Assistant", event.delta)
          when Events::ToolCall
            streamed = true
            print_tool_call(event.tool_call)
          when Events::ToolResult
            streamed = true
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

      finish_stream_block if streamed
      @prompt.say("\n#{colored("Assistant>", :green, :bold)} #{answer}\n") unless streamed || answer.to_s.empty?
      @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input)
      queued_inputs
    end

    def collect_queued_input(queued_inputs)
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
      answer = agent.ask(input) do |event|
        case event
        when Events::ReasoningDelta
          streamed = true
          print_block_delta("Reasoning", event.delta)
        when Events::AssistantDelta
          streamed = true
          print_block_delta("Assistant", event.delta)
        when Events::ToolCall
          streamed = true
          print_tool_call(event.tool_call)
        when Events::ToolResult
          streamed = true
          print_tool_result(event.tool_call, event.content)
        end
      end
      finish_stream_block if streamed
      @prompt.say("\n#{colored("Assistant>", :green, :bold)} #{answer}\n") unless streamed || answer.to_s.empty?
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

    def chat(messages, tools:, on_reasoning_delta: nil, on_assistant_delta: nil)
      @client.chat(messages, tools: tools, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta)
    rescue ArgumentError => e
      raise unless e.message.include?("on_reasoning_delta") || e.message.include?("on_assistant_delta")

      @client.chat(messages, tools: tools)
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
      function = tool_call["function"] || tool_call[:function] || {}
      function["name"] || function[:name] || "unknown_tool"
    end

    def tool_call_args(tool_call)
      function = tool_call["function"] || tool_call[:function] || {}
      parse_tool_arguments(function["arguments"] || function[:arguments])
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
      function = tool_call["function"] || tool_call[:function] || {}
      name = function["name"] || function[:name] || "unknown_tool"
      arguments = function["arguments"] || function[:arguments]
      args = parse_tool_arguments(arguments)

      if name == "run_shell_command"
        args["command"] || args[:command] || ""
      elsif args.empty?
        name.to_s
      else
        "#{name} #{JSON.dump(args)}"
      end
    end

    def parse_tool_arguments(arguments)
      return {} if arguments.nil? || arguments.empty?
      return arguments if arguments.is_a?(Hash)

      JSON.parse(arguments)
    rescue JSON::ParserError
      {}
    end
  end
end
