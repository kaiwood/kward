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
      message = @client.chat(Conversation.new.tap { |conversation| conversation.append_user(input) }.messages, tools: ToolRegistry.new.schemas)
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
        input = @prompt.ask("You>")
        break if input.nil?

        input = input.strip
        next if input.empty?
        break if ["/exit", "/quit"].include?(input)
        if input == "/status"
          @prompt.say("\nAssistant> #{STATUS_MESSAGE}\n")
          next
        end

        answer = agent.ask(input)
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
  end
end
