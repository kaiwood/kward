require_relative "../../kward"
require_relative "prompt_agent"

module Kward
  # Lazy, in-memory shell conversation with no chat composer or tab startup.
  class StandaloneAgent
    def initialize(client: Client.new)
      @client = client
    end

    def ask(instruction, shell, cancellation:)
      @agent ||= build_agent(shell.cwd)
      session = ShellPromptSession.new(shell)
      registry = @agent.tool_registry.for_shell_prompt(session)
      answer = @agent.ask(ShellPrompt.input(instruction, session.context), display_input: "? #{instruction}",
                          tool_registry: registry, cancellation: cancellation)
      [answer, session.prepared_command]
    end

    private

    def build_agent(cwd)
      config = ConfigFiles.read_config
      workspace = WorkspaceFactory.build(root: cwd, guardrails: ConfigFiles.workspace_guardrails_enabled?(config), config: config)
      registry = ToolRegistry.new(workspace: workspace, allowed_tool_names: [])
      ShellPromptAgent.build(client: @client, registry: registry, workspace_root: cwd, config: config,
                             provider: @client.current_provider, model: @client.current_model,
                             reasoning_effort: @client.current_reasoning_effort)
    end
  end
end
