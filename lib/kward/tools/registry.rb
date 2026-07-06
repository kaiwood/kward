require_relative "../config_files"
require_relative "../conversation"
require_relative "ask_user_question"
require_relative "code_search"
require_relative "context_budget_stats"
require_relative "context_for_task"
require_relative "edit_file"
require_relative "fetch_content"
require_relative "fetch_raw"
require_relative "list_directory"
require_relative "mcp_tool"
require_relative "read_file"
require_relative "read_skill"
require_relative "run_shell_command"
require_relative "summarize_file_structure"
require_relative "retrieve_tool_output"
require_relative "web_search"
require_relative "write_file"
require_relative "search/code"
require_relative "search/web"
require_relative "search/web_fetch"
require_relative "tool_call"
require_relative "../mcp/server_config"
require_relative "../telemetry/logger"
require_relative "../tool_output_compactor"
require_relative "../workspace"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Exposes local workspace, search, skill, and interaction tools to the model
  # and dispatches tool calls into the active conversation.
  #
  # `ToolRegistry` is the boundary between model-requested function calls and
  # Ruby tool objects. It owns schema exposure and transcript persistence for
  # tool results; individual tools own validation and side effects. Keep frontend
  # policy outside this class by passing dependencies such as `workspace` and
  # `prompt` from CLI or RPC setup.
  #
  # A tool may exist in `@tools` but not be advertised in `schemas`. This allows
  # restored transcripts or compatibility callers to dispatch known tools while
  # config and frontend capability checks decide what the model can request next.
  #
  # Tool schemas are the strict output contract advertised to models and clients.
  # Incoming calls are intentionally more tolerant: extra fields are ignored by
  # individual tools, and legacy-compatible shapes are accepted where already
  # supported. Required fields and invalid required values should still return
  # explicit tool errors.
  class ToolRegistry
    # Tool schemas advertised to the model for the current frontend and config.
    #
    # @return [Array<Hash>] tool schemas currently advertised to the model
    attr_reader :schemas, :writer_id

    # Builds tool objects and the schema list for the current frontend/config.
    #
    # @param workspace [Workspace] filesystem/shell boundary used by local tools
    # @param prompt [Object, nil] interactive prompt bridge; must implement
    #   `ask_user_question` before that tool is advertised
    # @param web_search [WebSearch] live web search implementation
    # @param web_fetch [WebFetch] specific URL fetch implementation
    # @param code_search [CodeSearch] public source/package search implementation
    # @param web_search_enabled [Boolean, nil] override for web search exposure
    # @param skills [Array<ConfigFiles::Skill>, nil] override discovered skills
    # @param ask_user_question_enabled [Boolean, nil] override question exposure
    def initialize(workspace: Workspace.new, prompt: nil, web_search: WebSearch.new, web_fetch: WebFetch.new, code_search: CodeSearch.new, web_search_enabled: nil, skills: nil, ask_user_question_enabled: nil, allowed_tool_names: nil, write_lock: nil, writer_id: nil, tool_output_compactor: ToolOutputCompactor.new, telemetry_logger: TelemetryLogger.new, context_budget_meter: nil, mcp_clients: nil, tool_approval: nil)
      @workspace = workspace
      @prompt = prompt
      @web_search = web_search
      @web_fetch = web_fetch
      @code_search = code_search
      @skills = skills
      @web_search_enabled = web_search_enabled
      @ask_user_question_enabled = ask_user_question_enabled
      @allowed_tool_names = allowed_tool_names&.map(&:to_s)
      @write_lock = write_lock
      @writer_id = writer_id
      @tool_output_compactor = tool_output_compactor
      @telemetry_logger = telemetry_logger
      @context_budget_meter = context_budget_meter
      @tool_approval = tool_approval
      @mcp_clients = if mcp_clients
                       mcp_clients
                     elsif @allowed_tool_names
                       []
                     else
                       MCP::ServerConfig.clients_from_config(ConfigFiles.read_config)
                     end
      @tools = build_tools.freeze
      @schemas = build_schema_tools.map { |tool| schema_with_metadata(tool) }.freeze
    end

    # Executes a model-requested tool call and appends the result to the
    # conversation transcript.
    #
    # Unknown tools are recorded as tool results instead of raising. That keeps
    # the conversation valid for the model and lets the assistant recover by
    # choosing an advertised tool on the next turn.
    #
    # @param tool_call [Hash] model tool call payload
    # @param conversation [Conversation] active conversation
    # @return [String] tool output content appended to the conversation
    def dispatch(tool_call, conversation, cancellation: nil)
      cancellation&.raise_if_cancelled!
      name = ToolCall.name(tool_call)
      args = ToolCall.arguments(tool_call)
      tool = @tools[name]

      original_content = if tool
                           if mutation_tool?(name) && !write_lock_owned?
                             "Workspace write denied: another worker owns the write lock."
                           elsif tool_approval_denied?(tool_call, name, args, cancellation)
                             "Declined: tool execution denied by user: #{name}"
                           else
                             tool.call(args, conversation, cancellation: cancellation)
                           end
                         else
                           "Unknown tool: #{name}"
                         end
      original_content = Conversation.normalize_tool_content(original_content)
      duplicate_id = conversation.tool_output_artifact_id_for(tool_name: name, content: original_content)
      content = original_content
      if reusable_duplicate_output?(name) && conversation.tool_output_artifacts.key?(duplicate_id)
        content = "[Same as previous tool output #{duplicate_id}; not repeated. Use retrieve_tool_output to inspect it.]"
      end

      artifact_id = nil
      model_content = @tool_output_compactor.compact(name, content) do
        artifact_id ||= conversation.store_tool_output_artifact(tool_name: name, content: original_content)
      end
      record_context_budget(conversation, name, before: original_content, after: model_content)
      log_tool_output_compaction(name, artifact_id: artifact_id, before: original_content, after: model_content) if model_content != original_content
      conversation.append_tool(
        tool_call_id: tool_call["id"] || tool_call[:id],
        name: name,
        content: model_content
      )
      conversation.append_tool_execution(tool_call: tool_call, content: original_content)

      model_content
    end

    def metadata_for(name)
      tool = @tools[name.to_s]
      return unknown_tool_metadata(name) unless tool

      tool_metadata(tool)
    end

    private

    def schema_with_metadata(tool)
      tool.schema.merge(metadata: tool_metadata(tool))
    end

    def tool_metadata(tool)
      if tool.is_a?(Tools::MCPTool)
        {
          source: "mcp",
          displayName: tool.display_name,
          serverName: tool.server_name,
          remoteName: tool.remote_name
        }
      else
        {
          source: source_for_tool(tool),
          displayName: tool.name
        }
      end
    end

    def source_for_tool(tool)
      case tool
      when Tools::WebSearch, Tools::FetchContent, Tools::FetchRaw
        "web"
      when Tools::ReadSkill
        "skill"
      when Tools::AskUserQuestion
        "ui"
      else
        "builtin"
      end
    end

    def unknown_tool_metadata(name)
      {
        source: "unknown",
        displayName: name.to_s
      }
    end

    def record_context_budget(conversation, name, before:, after:)
      meter = conversation.respond_to?(:context_budget_meter) ? conversation.context_budget_meter : @context_budget_meter
      return unless meter
      return if name.to_s == "context_budget_stats"

      saved = meter.record(tool_name: name, original_bytes: before.bytesize, returned_bytes: after.bytesize)
      @telemetry_logger.log(
        "compaction",
        "context_budget",
        "tool_name" => name,
        "bytes_before" => before.bytesize,
        "bytes_after" => after.bytesize,
        "bytes_saved" => saved
      )
    end

    def reusable_duplicate_output?(name)
      name.to_s != "read_skill"
    end

    def log_tool_output_compaction(name, artifact_id:, before:, after:)
      @telemetry_logger.log(
        "compaction",
        "tool_output",
        "tool_name" => name,
        "artifact_id" => artifact_id,
        "bytes_before" => before.bytesize,
        "bytes_after" => after.bytesize,
        "bytes_saved" => before.bytesize - after.bytesize
      )
    end

    def mutation_tool?(name)
      ToolCall.write_lock_required?(name)
    end

    def tool_approval_denied?(tool_call, name, args, cancellation)
      return false unless @tool_approval

      @tool_approval.call(tool_call: tool_call, name: name, args: args, cancellation: cancellation) == false
    end

    def write_lock_owned?
      return true unless @write_lock

      @write_lock.owned_by?(@writer_id)
    end

    def build_tools
      tools = all_tools
      tools = tools.select { |tool| @allowed_tool_names.include?(tool.name) } if @allowed_tool_names
      tools.to_h { |tool| [tool.name, tool] }
    end

    def build_schema_tools
      tools = @tools.values_at(
        "list_directory", "read_file", "write_file", "edit_file", "run_shell_command", "code_search", "summarize_file_structure", "context_for_task", "context_budget_stats", "retrieve_tool_output"
      )
      tools.concat(@tools.values_at("web_search", "fetch_content", "fetch_raw")) if web_search_available?
      tools.concat(@tools.values.select { |tool| tool.is_a?(Tools::MCPTool) })
      tools << @tools["read_skill"] if skills_available?
      tools << @tools["ask_user_question"] if ask_user_question_available?
      tools.compact
    end

    def all_tools
      core_tools + [
        Tools::WebSearch.new(web_search: @web_search),
        Tools::FetchContent.new(web_fetch: @web_fetch),
        Tools::FetchRaw.new(web_fetch: @web_fetch),
        Tools::ReadSkill.new(skills: discovered_skills),
        Tools::AskUserQuestion.new(prompt: @prompt)
      ] + mcp_tool_values
    end

    def core_tools
      [
        Tools::ListDirectory.new(workspace: @workspace),
        Tools::ReadFile.new(workspace: @workspace),
        Tools::WriteFile.new(workspace: @workspace),
        Tools::EditFile.new(workspace: @workspace),
        Tools::RunShellCommand.new(workspace: @workspace),
        Tools::CodeSearch.new(code_search: @code_search),
        Tools::SummarizeFileStructure.new(workspace: @workspace),
        Tools::ContextForTask.new(workspace: @workspace),
        Tools::ContextBudgetStats.new(context_budget_meter: @context_budget_meter),
        Tools::RetrieveToolOutput.new
      ]
    end

    def web_search_available?
      return @web_search_enabled unless @web_search_enabled.nil?
      return @web_search.available? if @web_search.respond_to?(:available?)

      true
    end

    def discovered_skills
      @discovered_skills ||= @skills.nil? ? ConfigFiles.skills : @skills
    end

    def skills_available?
      discovered_skills.any?
    end

    def mcp_tool_values
      @mcp_tool_values ||= build_mcp_tools
    end

    def build_mcp_tools
      Array(@mcp_clients).flat_map do |client|
        client.list_tools.map do |tool|
          Tools::MCPTool.new(server_name: client.name, client: client, tool: tool)
        end
      rescue StandardError => e
        @telemetry_logger.log(
          "mcp",
          "server_unavailable",
          "server" => client.respond_to?(:name) ? client.name : "unknown",
          "error" => e.message
        )
        []
      end
    end

    def ask_user_question_available?
      return false if @ask_user_question_enabled == false

      @prompt.respond_to?(:ask_user_question)
    end

  end
end
