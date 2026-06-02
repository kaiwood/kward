require "json"
require "tty-prompt"
require_relative "agent"
require_relative "client"
require_relative "events"
require_relative "openai_oauth"
require_relative "tool_registry"
require_relative "workspace"

module Kward
  class CLI
    STATUS_MESSAGE = "This is a totally important status message about a non-existing status. Hi ChatGPT 👋"

    def initialize(argv: ARGV, stdin: STDIN, prompt: TTY::Prompt.new, client: Client.new)
      @argv = argv
      @stdin = stdin
      @prompt = prompt
      @client = client
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
      @prompt.say("Saved OpenAI OAuth login to #{path}")
    end

    def interactive_loop(agent: nil)
      setup_interactive_prompt
      agent ||= Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(workspace: Workspace.new, prompt: @prompt)
      )

      @prompt.say("Ruby CLI Agent")
      help = "Ask a question and press Enter. Type /exit to quit."
      help += " Use Shift+Enter for new lines." if prompt_interface?
      @prompt.say("#{help}\n")

      loop do
        input = @prompt.ask("You>") || ""

        command = input.strip
        next if command.empty?
        break if command == "/exit"
        if command == "/status"
          @prompt.say("\nAssistant> #{STATUS_MESSAGE}\n")
          next
        end

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
        @prompt.say("\nAssistant> #{answer}\n") unless streamed || answer.empty?
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

    def setup_interactive_prompt
      return unless @stdin.tty?
      return unless @prompt.is_a?(TTY::Prompt)

      prompt_interface = load_prompt_interface
      return unless prompt_interface

      @prompt = prompt_interface.new
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
      if prompt_interface?
        @prompt.start_stream_block("Tool output")
        @prompt.write_delta("#{tool_command(tool_call)}\n")
        @prompt.write_delta(content)
        @prompt.write_delta("\n") unless content.to_s.end_with?("\n")
        @prompt.finish_stream_block
      else
        start_stream_block("Tool output")
        puts tool_command(tool_call)
        print content
        puts unless content.to_s.end_with?("\n")
        $stdout.flush
        @stream_block = nil
      end
    end

    def start_stream_block(label)
      return if @stream_block == label

      puts if @stream_block
      puts "\n#{label}>"
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
