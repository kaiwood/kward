require_relative "../config_files"
require_relative "ask_user_question"
require_relative "code_search"
require_relative "edit_file"
require_relative "list_directory"
require_relative "read_file"
require_relative "read_skill"
require_relative "run_shell_command"
require_relative "web_search"
require_relative "write_file"
require_relative "search/code"
require_relative "search/web"
require_relative "tool_call"
require_relative "../workspace"

module Kward
  # Exposes local workspace, search, skill, and interaction tools to the model
  # and dispatches approved tool calls into the active conversation.
  class ToolRegistry
    # Tool schemas advertised to the model for the current frontend and config.
    #
    # @return [Array<Hash>]
    attr_reader :schemas

    def initialize(workspace: Workspace.new, prompt: nil, web_search: WebSearch.new, code_search: CodeSearch.new, web_search_enabled: nil, skills: nil, ask_user_question_enabled: nil)
      @workspace = workspace
      @prompt = prompt
      @web_search = web_search
      @code_search = code_search
      @skills = skills
      @web_search_enabled = web_search_enabled
      @ask_user_question_enabled = ask_user_question_enabled
      @tools = build_tools.freeze
      @schemas = build_schema_tools.map(&:schema).freeze
    end

    # Executes a model-requested tool call and appends the result to the
    # conversation transcript.
    #
    # @param tool_call [Hash] model tool call payload
    # @param conversation [Conversation] active conversation
    # @return [String] tool output content appended to the conversation
    def dispatch(tool_call, conversation, cancellation: nil)
      cancellation&.raise_if_cancelled!
      name = ToolCall.name(tool_call)
      args = ToolCall.arguments(tool_call)
      tool = @tools[name]

      content = if tool
                  tool.call(args, conversation, cancellation: cancellation)
                else
                  "Unknown tool: #{name}"
                end

      conversation.append_tool(
        tool_call_id: tool_call["id"] || tool_call[:id],
        name: name,
        content: content
      )
      conversation.append_tool_execution(tool_call: tool_call, content: content)

      content
    end

    private

    def build_tools
      all_tools.to_h { |tool| [tool.name, tool] }
    end

    def build_schema_tools
      tools = core_tools
      tools << @tools["web_search"] if web_search_available?
      tools << @tools["read_skill"] if skills_available?
      tools << @tools["ask_user_question"] if ask_user_question_available?
      tools
    end

    def all_tools
      core_tools + [
        Tools::WebSearch.new(web_search: @web_search),
        Tools::ReadSkill.new,
        Tools::AskUserQuestion.new(prompt: @prompt)
      ]
    end

    def core_tools
      [
        Tools::ListDirectory.new(workspace: @workspace),
        Tools::ReadFile.new(workspace: @workspace),
        Tools::WriteFile.new(workspace: @workspace),
        Tools::EditFile.new(workspace: @workspace),
        Tools::RunShellCommand.new(workspace: @workspace),
        Tools::CodeSearch.new(code_search: @code_search)
      ]
    end

    def web_search_available?
      return @web_search_enabled unless @web_search_enabled.nil?
      return @web_search.available? if @web_search.respond_to?(:available?)

      true
    end

    def skills_available?
      skills = @skills.nil? ? ConfigFiles.skills : @skills
      skills.any?
    end

    def ask_user_question_available?
      return false if @ask_user_question_enabled == false

      @prompt.respond_to?(:ask_user_question)
    end

  end
end
