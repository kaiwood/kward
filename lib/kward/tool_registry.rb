require "json"
require_relative "config_files"
require_relative "web_research"
require_relative "workspace"

module Kward
  class ToolRegistry
    attr_reader :schemas

    def initialize(workspace: Workspace.new, prompt: nil, web_research: WebResearch.new)
      @workspace = workspace
      @prompt = prompt
      @web_research = web_research
      @schemas = [list_directory_schema, read_file_schema, write_file_schema, edit_file_schema, run_shell_command_schema, web_research_schema, read_skill_schema, ask_user_question_schema].freeze
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
                when "read_skill"
                  read_skill(args)
                when "ask_user_question"
                  ask_user_question(args)
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

    def read_skill(args)
      name = args["name"] || args[:name] || ""
      path = args["path"] || args[:path]

      ConfigFiles.read_skill_file(name, path)
    end

    def ask_user_question(args)
      return "Error: ask_user_question requires interactive prompt support." unless @prompt.respond_to?(:ask_user_question)

      questions = validated_questions(args)
      return questions if questions.is_a?(String)

      answers = @prompt.ask_user_question(questions)
      return "Cancelled." if answers.nil?

      answers.map { |answer| "#{answer[:question]}: #{answer[:answer]}" }.join("\n")
    end

    def validated_questions(args)
      questions = args["questions"] || args[:questions]
      return "Error: ask_user_question requires questions." unless questions.is_a?(Array)
      return "Error: ask_user_question requires 1 to 4 questions." unless questions.length.between?(1, 4)

      questions.map.with_index(1) do |question, index|
        return "Error: question #{index} must be an object." unless question.respond_to?(:key?)
        return "Error: question #{index} uses unsupported multiSelect." if question.key?("multiSelect") || question.key?(:multiSelect)

        text = question_value(question, :question).to_s.strip
        header = question_value(question, :header).to_s.strip
        options = question_value(question, :options)
        return "Error: question #{index} requires question and header." if text.empty? || header.empty?
        return "Error: question #{index} requires 2 to 4 options." unless options.is_a?(Array) && options.length.between?(2, 4)

        normalized_options = options.map.with_index(1) do |option, option_index|
          return "Error: question #{index} option #{option_index} must be an object." unless option.respond_to?(:key?)
          return "Error: question #{index} option #{option_index} uses unsupported preview." if option.key?("preview") || option.key?(:preview)

          label = question_value(option, :label).to_s.strip
          description = question_value(option, :description).to_s.strip
          return "Error: question #{index} option #{option_index} requires label and description." if label.empty? || description.empty?

          { label: label, description: description }
        end

        { question: text, header: header, options: normalized_options }
      end
    end

    def question_value(object, key)
      return object[key] if object.key?(key)
      return object[key.to_s] if object.key?(key.to_s)

      nil
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
          description: "Search the live web. Provider fallback order is Exa (API key if configured, otherwise keyless Exa MCP), Perplexity when configured, Gemini when configured, then legacy DuckDuckGo/SearXNG.",
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
                description: "Optional maximum results per query. Defaults to 5 and is capped at 20."
              },
              provider: {
                type: "string",
                enum: %w[auto exa perplexity gemini legacy duckduckgo],
                description: "Optional provider override. Defaults to auto."
              },
              recency_filter: {
                type: "string",
                enum: %w[day week month year],
                description: "Optional recency filter."
              },
              domain_filter: {
                type: "array",
                description: "Optional domains to include, or prefix with '-' to exclude.",
                items: { type: "string" }
              }
            },
            required: ["queries"],
            additionalProperties: false
          }
        }
      }
    end

    def read_skill_schema
      {
        type: "function",
        function: {
          name: "read_skill",
          description: "Read configured skill instructions or related files from the Kward config skills directory.",
          parameters: {
            type: "object",
            properties: {
              name: { type: "string", description: "Configured skill name." },
              path: { type: "string", description: "Optional path relative to the skill folder. Defaults to SKILL.md." }
            },
            required: ["name"],
            additionalProperties: false
          }
        }
      }
    end

    def ask_user_question_schema
      {
        type: "function",
        function: {
          name: "ask_user_question",
          description: "Ask the user one to four structured clarification questions in interactive mode. Supports single-select choices and custom typed answers.",
          parameters: {
            type: "object",
            properties: {
              questions: {
                type: "array",
                minItems: 1,
                maxItems: 4,
                items: {
                  type: "object",
                  properties: {
                    question: { type: "string", description: "The question to ask." },
                    header: { type: "string", description: "Short label shown in the overlay." },
                    options: {
                      type: "array",
                      minItems: 2,
                      maxItems: 4,
                      items: {
                        type: "object",
                        properties: {
                          label: { type: "string", description: "Choice label." },
                          description: { type: "string", description: "Choice explanation." }
                        },
                        required: ["label", "description"],
                        additionalProperties: false
                      }
                    }
                  },
                  required: ["question", "header", "options"],
                  additionalProperties: false
                }
              }
            },
            required: ["questions"],
            additionalProperties: false
          }
        }
      }
    end
  end
end
