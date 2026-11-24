module Kward
  # Shared shell-agent model selection and scoped per-session tools.
  module ShellPromptAgent
    def self.build(client:, registry:, workspace_root:, provider:, model:, reasoning_effort:, config: ConfigFiles.read_config)
      configured_provider = ConfigFiles.shell_agent_provider(config)
      conversation = Conversation.new(
        system_message: ShellPrompt.system_message,
        refresh_system_message: false,
        workspace_root: workspace_root,
        provider: configured_provider || provider,
        model: ConfigFiles.shell_agent_model(config) || (configured_provider ? nil : model),
        reasoning_effort: ConfigFiles.shell_agent_reasoning_effort(config) || (configured_provider ? nil : reasoning_effort)
      )
      Agent.new(client: client, tool_registry: registry, conversation: conversation,
                strict_provider: !configured_provider.nil?, warning_sink: ConfigFiles.warning_sink)
    end
  end
end
