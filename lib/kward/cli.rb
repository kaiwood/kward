require "tty-prompt"
require_relative "agent"
require_relative "client"
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
        puts one_shot(first_prompt)
        return
      end

      stdin_prompt = piped_prompt
      unless stdin_prompt.empty?
        puts one_shot(stdin_prompt)
        return
      end

      interactive_loop
    end

    def one_shot(input)
      message = chat(Conversation.new.tap { |conversation| conversation.append_user(input) }.messages, tools: ToolRegistry.new.schemas, on_reasoning_delta: method(:print_reasoning_delta))
      puts if message["reasoning_summary"] && !message["reasoning_summary"].empty?
      message.fetch("content", "")
    end

    def login(oauth: OpenAIOAuth.new)
      path = oauth.login(prompt: @prompt)
      @prompt.say("Saved OpenAI OAuth login to #{path}")
    end

    def interactive_loop(agent: nil)
      agent ||= Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(workspace: Workspace.new, prompt: @prompt)
      )

      @prompt.say("Ruby CLI Agent")
      @prompt.say("Ask a question and press Enter. Type /exit to quit.\n")

      loop do
        input = @prompt.ask("You>") || ""

        input = input.strip
        next if input.empty?
        break if input == "/exit"
        if input == "/status"
          @prompt.say("\nAssistant> #{STATUS_MESSAGE}\n")
          next
        end

        printed_reasoning = false
        answer = agent.ask(input, on_reasoning_delta: lambda do |delta|
          unless printed_reasoning
            @prompt.say("\nReasoning>")
            printed_reasoning = true
          end
          print_reasoning_delta(delta)
        end)
        @prompt.say("") if printed_reasoning
        @prompt.say("\nAssistant> #{answer}\n") unless answer.empty?
      end

      agent.conversation
    rescue Interrupt
      @prompt.say("\nGoodbye.")
      agent&.conversation
    end

    def piped_prompt
      return "" if @stdin.tty?

      @stdin.read.strip
    end

    private

    def chat(messages, tools:, on_reasoning_delta: nil)
      @client.chat(messages, tools: tools, on_reasoning_delta: on_reasoning_delta)
    rescue ArgumentError => e
      raise unless e.message.include?("on_reasoning_delta")

      @client.chat(messages, tools: tools)
    end

    def print_reasoning_delta(delta)
      print delta
      $stdout.flush
    end
  end
end
