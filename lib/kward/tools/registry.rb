require_relative "../config_files"
require_relative "../conversation"
require_relative "../hooks"
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
require_relative "../permissions/policy"
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
  # @api public
  class ToolRegistry
    # Tool schemas advertised to the model for the current frontend and config.
    #
    # @return [Array<Hash>] tool schemas currently advertised to the model
    attr_reader :schemas

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
    def initialize(workspace: Workspace.new, prompt: nil, web_search: WebSearch.new, web_fetch: WebFetch.new, code_search: CodeSearch.new, web_search_enabled: nil, skills: nil, ask_user_question_enabled: nil, allowed_tool_names: nil, tool_output_compactor: ToolOutputCompactor.new, telemetry_logger: TelemetryLogger.new, context_budget_meter: nil, mcp_clients: nil, tool_approval: nil, permission_policy: nil, hook_manager: nil, hook_context: nil)
      @workspace = workspace
      @prompt = prompt
      @web_search = web_search
      @web_fetch = web_fetch
      @code_search = code_search
      @skills = skills
      @web_search_enabled = web_search_enabled
      @ask_user_question_enabled = ask_user_question_enabled
      @allowed_tool_names = allowed_tool_names&.map(&:to_s)
      @tool_output_compactor = tool_output_compactor
      @telemetry_logger = telemetry_logger
      @context_budget_meter = context_budget_meter
      @tool_approval = tool_approval
      @permission_policy = permission_policy || Permissions::Policy.from_config(ConfigFiles.read_config)
      @hook_manager = hook_manager
      @hook_context = hook_context
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
                           before_tool = run_hook("tool_call_before", conversation, payload: tool_payload(name, args, tool_call))
                           args = hook_arguments(before_tool, args)
                           if before_tool.denied?
                             hook_denied_content(before_tool, "tool call denied: #{name}")
                           elsif before_tool.approval_required? && hook_approval_denied?(before_tool, tool_call, name, args, cancellation)
                             hook_denied_content(before_tool, "tool call approval denied: #{name}")
                           else
                             permission_decision = @permission_policy.decision_for(name, args, source: source_for_tool(tool))
                             if permission_decision.denied?
                               "Declined: #{permission_decision.reason}: #{name}"
                             elsif permission_decision.approval_required? && tool_approval_denied?(tool_call, name, args, cancellation)
                               "Declined: tool execution denied by user: #{name}"
                             else
                               execute_tool_with_hooks(tool, name, args, tool_call, conversation, cancellation)
                             end
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
      model_content = compact_tool_output(name, content, original_content, conversation) do
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

    # Returns frontend discovery metadata for a tool name.
    #
    # Unknown names return metadata with an unknown source rather than raising,
    # which lets RPC clients render restored or unsupported tool calls safely.
    #
    # @param name [String, #to_s] exposed tool name
    # @return [Hash] source, display name, and optional MCP identity
    # @api public
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

    def compact_tool_output(name, content, original_content, conversation, &store_artifact)
      before = run_hook("tool_output_compact_before", conversation, payload: {
        tool_name: name,
        bytes: content.bytesize,
        duplicate: content != original_content
      })
      return content if before.denied? || before.approval_required?

      compacted = @tool_output_compactor.compact(name, content, &store_artifact)
      run_hook("tool_output_compact_after", conversation, payload: {
        tool_name: name,
        bytes_before: content.bytesize,
        bytes_after: compacted.bytesize,
        compacted: compacted != content
      }) if compacted != content
      compacted
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

    def execute_tool_with_hooks(tool, name, args, tool_call, conversation, cancellation)
      args = run_shell_before_hooks(name, args, tool_call, conversation, cancellation)
      run_file_change_before_hooks(name, args, tool_call, conversation, cancellation)
      run_mcp_before_hooks(name, args, tool_call, conversation, cancellation)
      content = tool.call(args, conversation, cancellation: cancellation)
      run_mcp_after_hooks(name, args, content, conversation)
      run_shell_after_hooks(name, args, content, conversation)
      run_file_change_after_hooks(name, args, content, conversation)
      run_hook("tool_call_after", conversation, payload: tool_payload(name, args, tool_call).merge(content: content.to_s))
      content
    rescue HookDenied => e
      e.message
    rescue StandardError => e
      run_mcp_error_hooks(name, args, e, conversation)
      run_hook("tool_call_error", conversation, payload: tool_payload(name, args, tool_call).merge(error: e.message))
      raise
    end

    def run_mcp_before_hooks(name, args, tool_call, conversation, cancellation)
      return unless mcp_tool?(name)

      result = run_hook("mcp_tool_before", conversation, payload: mcp_payload(name, args))
      if result.denied?
        raise HookDenied, hook_denied_content(result, "MCP tool denied")
      end
      if result.approval_required? && hook_approval_denied?(result, tool_call, name, args, cancellation)
        raise HookDenied, hook_denied_content(result, "MCP tool approval denied")
      end
    end

    def run_mcp_after_hooks(name, args, content, conversation)
      return unless mcp_tool?(name)

      run_hook("mcp_tool_after", conversation, payload: mcp_payload(name, args).merge(content: content.to_s))
    end

    def run_mcp_error_hooks(name, args, error, conversation)
      return unless mcp_tool?(name)

      run_hook("mcp_tool_error", conversation, payload: mcp_payload(name, args).merge(error: error.message))
    end

    def run_shell_before_hooks(name, args, tool_call, conversation, cancellation)
      return args unless name.to_s == "run_shell_command"

      result = run_hook("shell_command_before", conversation, payload: shell_payload(args))
      if result.denied?
        raise HookDenied, hook_denied_content(result, "shell command denied")
      end
      if result.approval_required? && hook_approval_denied?(result, tool_call, name, args, cancellation)
        raise HookDenied, hook_denied_content(result, "shell command approval denied")
      end
      shell_arguments(result.payload, args)
    end

    def run_shell_after_hooks(name, args, content, conversation)
      return unless name.to_s == "run_shell_command"

      run_hook("shell_command_after", conversation, payload: shell_payload(args).merge(content: content.to_s))
    end

    def run_file_change_before_hooks(name, args, tool_call, conversation, cancellation)
      return unless ToolCall.file_change_tool?(name)

      result = run_hook("file_change_before", conversation, payload: file_change_payload(name, args))
      if result.denied?
        raise HookDenied, hook_denied_content(result, "file change denied")
      end
      if result.approval_required? && hook_approval_denied?(result, tool_call, name, args, cancellation)
        raise HookDenied, hook_denied_content(result, "file change approval denied")
      end
    end

    def run_file_change_after_hooks(name, args, content, conversation)
      return unless ToolCall.file_change_tool?(name)
      return unless content.to_s.start_with?("Wrote ", "Edited ")

      run_hook("file_change_after", conversation, payload: file_change_payload(name, args).merge(content: content.to_s))
    end

    HookDenied = Class.new(StandardError)

    def run_hook(name, conversation, payload: {})
      return Hooks::Manager::Result.new(event: nil, decision: Hooks::Decision.allow, decisions: [], warnings: [], messages: [], payload: payload) unless @hook_manager

      @hook_manager.run(Hooks::Event.new(
        name: name,
        workspace: { root: @workspace.respond_to?(:root) ? @workspace.root.to_s : nil },
        payload: payload
      ), context: @hook_context || default_hook_context(conversation))
    end

    def default_hook_context(conversation)
      return nil unless defined?(PluginRegistry::Context)

      PluginRegistry::Context.new(conversation: conversation, workspace_root: @workspace.respond_to?(:root) ? @workspace.root.to_s : Dir.pwd)
    end

    def tool_payload(name, args, tool_call)
      metadata = metadata_for(name)
      {
        tool_name: name,
        arguments: args,
        tool_call_id: tool_call["id"] || tool_call[:id],
        source: metadata[:source] || metadata["source"],
        server_name: metadata[:serverName] || metadata["serverName"],
        remote_name: metadata[:remoteName] || metadata["remoteName"]
      }.compact
    end

    def hook_arguments(result, fallback)
      payload_arguments = result.payload[:arguments] || result.payload["arguments"]
      payload_arguments.is_a?(Hash) ? payload_arguments : fallback
    end

    def mcp_payload(name, args)
      tool_payload(name, args, {}).slice(:tool_name, :arguments, :source, :server_name, :remote_name)
    end

    def shell_payload(args)
      {
        tool_name: "run_shell_command",
        command: args[:command] || args["command"],
        timeout_seconds: args[:timeout_seconds] || args["timeout_seconds"] || Workspace::DEFAULT_COMMAND_TIMEOUT_SECONDS,
        cwd: @workspace.respond_to?(:root) ? @workspace.root.to_s : nil
      }.compact
    end

    def file_change_payload(name, args)
      operation = name.to_s.start_with?("edit") ? "edit" : "write"
      path = args[:path] || args["path"]
      payload = {
        tool_name: name,
        operation: operation,
        path: path,
        files: [{ path: path, operation: operation }]
      }
      if operation == "edit"
        payload[:edits] = args[:edits] || args["edits"]
      else
        payload[:content] = args[:content] || args["content"]
      end
      payload.compact
    end

    def shell_arguments(payload, fallback)
      fallback.merge(
        command: payload[:command] || payload["command"] || fallback[:command] || fallback["command"],
        timeout_seconds: payload[:timeout_seconds] || payload["timeout_seconds"] || fallback[:timeout_seconds] || fallback["timeout_seconds"]
      )
    end

    def hook_denied_content(result, fallback)
      "Declined: #{result.decision.message || fallback}"
    end

    def hook_approval_denied?(result, tool_call, name, args, cancellation)
      return true unless @tool_approval

      approval_args = args.merge("hook_message" => result.decision.message)
      @tool_approval.call(tool_call: tool_call, name: name, args: approval_args, cancellation: cancellation) == false
    end

    def mcp_tool?(name)
      metadata = metadata_for(name)
      (metadata[:source] || metadata["source"]).to_s == "mcp"
    end

    def tool_approval_denied?(tool_call, name, args, cancellation)
      return false unless @tool_approval

      @tool_approval.call(tool_call: tool_call, name: name, args: args, cancellation: cancellation) == false
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

    def discovered_skills(workspace_root: nil)
      return @skills unless @skills.nil?

      @discovered_skills ||= {}
      root = workspace_root || (@workspace.respond_to?(:root) ? @workspace.root : Dir.pwd)
      @discovered_skills[root] ||= ConfigFiles.skills(workspace_root: root)
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
