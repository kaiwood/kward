# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Builders for frontend-neutral runtime state payloads.
    module RuntimePayloads
      module_function

      def state(session:, model:, streaming:, steering_supported:, auto_compaction_reserve_tokens:, active_persona_label:, message_count:, pending_count:, compaction_enabled:, workspace_guardrails_enabled:)
        {
          model: model,
          thinkingLevel: model[:reasoningEffort],
          isStreaming: streaming,
          isCompacting: false,
          steeringMode: steering_supported ? "in-flight" : "one-at-a-time",
          followUpMode: "one-at-a-time",
          sessionFile: session[:path],
          rpcSessionId: session[:id],
          persistentSessionId: session[:persistentId],
          sessionName: session[:name],
          autoCompactionEnabled: compaction_enabled,
          autoCompactionReserveTokens: auto_compaction_reserve_tokens,
          workspaceGuardrailsEnabled: workspace_guardrails_enabled,
          autoRetryEnabled: false,
          defaultProvider: model[:provider],
          defaultModel: default_model_label(model),
          defaultThinkingLevel: model[:reasoningEffort],
          activePersonaLabel: active_persona_label,
          hideThinkingBlock: false,
          quietStartup: false,
          transport: "kward-rpc",
          imageAutoResize: false,
          blockImages: false,
          enabledModels: [],
          enableSkillCommands: true,
          messageCount: message_count,
          pendingMessageCount: pending_count
        }.compact
      end

      def stats(session:, counts:, model:, auto_compaction_reserve_tokens:, context_usage:, compaction_enabled:)
        {
          sessionFile: session[:path],
          rpcSessionId: session[:id],
          persistentSessionId: session[:persistentId],
          sessionName: session[:name],
          userMessages: counts[:userMessages],
          assistantMessages: counts[:assistantMessages],
          toolCalls: counts[:toolCalls],
          toolResults: counts[:toolResults],
          totalMessages: counts[:totalMessages],
          usingSubscription: ["Codex", "Anthropic"].include?(model[:provider]),
          autoCompactionEnabled: compaction_enabled,
          autoCompactionReserveTokens: auto_compaction_reserve_tokens,
          contextUsage: context_usage
        }.compact
      end

      def session(rpc_session, modified_at:, active_persona_label: nil)
        {
          id: rpc_session.id,
          persistentId: rpc_session.session.id,
          path: rpc_session.session.path,
          workspaceRoot: rpc_session.workspace_root,
          cwd: rpc_session.session.cwd.to_s.empty? ? rpc_session.workspace_root : rpc_session.session.cwd,
          name: rpc_session.session.name,
          createdAt: rpc_session.session.created_at&.utc&.iso8601(3),
          modifiedAt: modified_at&.utc&.iso8601(3),
          parentId: rpc_session.session.parent_id,
          parentPath: rpc_session.session.parent_path,
          activePersonaLabel: active_persona_label
        }.compact
      end

      def default_model_label(model)
        return nil if model[:provider].to_s.empty? || model[:id].to_s.empty?

        "#{model[:provider]}/#{model[:id]}"
      end
    end
  end
end
