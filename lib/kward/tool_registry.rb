require "json"
require_relative "web_research"
require_relative "workspace"

module Kward
  class ToolRegistry
    attr_reader :schemas

    def initialize(workspace: Workspace.new, prompt: nil, web_research: WebResearch.new)
      @workspace = workspace
      @prompt = prompt
      @web_research = web_research
      @schemas = [list_directory_schema, read_file_schema, write_file_schema, edit_file_schema, run_shell_command_schema, web_research_schema].freeze
    end

    def dispatch(tool_call, conversation)
      function = tool_call["function"] || tool_call[:function] || {}
      name = function["name"] || function[:name]
      args = parse_arguments(function["arguments"] || function[:arguments])

      content = case name
                when "list_directory"
                  @workspace.list_directory(args["path"] || args[:path] || ".")
                when "read_file"
                  read_file(args, conversation)
                when "write_file"
                  write_file(args, conversation)
                when "edit_file"
                  edit_file(args, conversation)
                when "run_shell_command"
                  run_shell_command(args)
                when "web_research"
                  @web_research.search(args)
                else
                  "Unknown tool: #{name}"
                end

      conversation.append_tool(
        tool_call_id: tool_call["id"] || tool_call[:id],
        name: name,
        content: content
      )

      content
    end

    private

    def read_file(args, conversation)
      path = args["path"] || args[:path] || ""
      content = @workspace.read_file(path)
      conversation.mark_read(@workspace.resolved_path(path)) unless content.start_with?("Error:")
      content
    end

    def write_file(args, conversation)
      path = args["path"] || args[:path] || ""
      content = args["content"] || args[:content] || ""

      @workspace.write_file(path, content, read_paths: conversation.read_paths)
    end

    def edit_file(args, conversation)
      path = args["path"] || args[:path] || ""
      edits = args["edits"] || args[:edits] || []

      @workspace.edit_file(path, edits, read_paths: conversation.read_paths)
    end

    def run_shell_command(args)
      command = args["command"] || args[:command] || ""
      timeout_seconds = args["timeout_seconds"] || args[:timeout_seconds] || Workspace::DEFAULT_COMMAND_TIMEOUT_SECONDS

      @workspace.run_shell_command(command, timeout_seconds: timeout_seconds)
    end

    def parse_arguments(arguments)
      return {} if arguments.nil? || arguments.empty?
      return arguments if arguments.is_a?(Hash)

      JSON.parse(arguments)
    rescue JSON::ParserError
      {}
    end

    def list_directory_schema
      {
        type: "function",
        function: {
          name: "list_directory",
          description: "List files and directories inside the current workspace.",
          parameters: {
            type: "object",
            properties: { path: { type: "string", description: "Workspace-relative directory path." } },
            required: ["path"],
            additionalProperties: false
          }
        }
      }
    end

    def read_file_schema
      {
        type: "function",
        function: {
          name: "read_file",
          description: "Read a text file inside the current workspace.",
          parameters: {
            type: "object",
            properties: { path: { type: "string", description: "Workspace-relative file path." } },
            required: ["path"],
            additionalProperties: false
          }
        }
      }
    end

    def write_file_schema
      {
        type: "function",
        function: {
          name: "write_file",
          description: "Write content to a file inside the current workspace. Existing files must be read first.",
          parameters: {
            type: "object",
            properties: {
              path: { type: "string", description: "Workspace-relative file path." },
              content: { type: "string", description: "Complete file content to write." }
            },
            required: ["path", "content"],
            additionalProperties: false
          }
        }
      }
    end

    def edit_file_schema
      {
        type: "function",
        function: {
          name: "edit_file",
          description: "Edit an existing file inside the current workspace using exact text replacement. Existing files must be read first. Each old_text must match exactly once and edits must not overlap.",
          parameters: {
            type: "object",
            properties: {
              path: { type: "string", description: "Workspace-relative file path." },
              edits: {
                type: "array",
                description: "One or more non-overlapping replacements matched against the original file content.",
                items: {
                  type: "object",
                  properties: {
                    old_text: { type: "string", description: "Exact text to replace. Must be unique in the original file." },
                    new_text: { type: "string", description: "Replacement text." }
                  },
                  required: ["old_text", "new_text"],
                  additionalProperties: false
                }
              }
            },
            required: ["path", "edits"],
            additionalProperties: false
          }
        }
      }
    end

    def run_shell_command_schema
      {
        type: "function",
        function: {
          name: "run_shell_command",
          description: "Run a shell command in the current workspace.",
          parameters: {
            type: "object",
            properties: {
              command: { type: "string", description: "Shell command to run from the workspace root." },
              timeout_seconds: { type: "integer", description: "Optional timeout in seconds. Defaults to 30." }
            },
            required: ["command"],
            additionalProperties: false
          }
        }
      }
    end

    def web_research_schema
      {
        type: "function",
        function: {
          name: "web_research",
          description: "Search the live web without an API key. Uses DuckDuckGo HTML search first, then public SearXNG instances as fallback.",
          parameters: {
            type: "object",
            properties: {
              queries: {
                type: "array",
                description: "One to four distinct web research queries. Prefer varied angles over near-duplicates.",
                items: { type: "string" },
                minItems: 1,
                maxItems: 4
              },
              max_results: {
                type: "integer",
                description: "Optional maximum results per query. Defaults to 5 and is capped at 10."
              }
            },
            required: ["queries"],
            additionalProperties: false
          }
        }
      }
    end
  end
end
