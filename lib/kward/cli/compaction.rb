# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # CLI slash-command helpers for manual context compaction.
    module CompactionCommands
      private

      def compact_context(agent, argument, cancellation: nil)
        before = run_lifecycle_hook("session_compact_before", conversation: agent.conversation, payload: { instructions: argument.to_s })
        if before.denied? || before.approval_required?
          runtime_output("Declined: #{before.decision.message || "session compaction denied"}")
          return
        end

        result = Compactor.new(
          conversation: agent.conversation,
          client: @client,
          tool_result_summarizer: lambda { |tool_call, content| tool_result_summary(tool_call, content) }
        ).compact(custom_instructions: argument, cancellation: cancellation)
        run_lifecycle_hook("session_compact_after", conversation: agent.conversation, payload: { old_message_count: result.old_message_count, new_message_count: result.new_message_count })
        runtime_output("Compacted context: #{result.old_message_count} messages -> #{result.new_message_count} messages.")
        result.summary
      rescue Compactor::NothingToCompact, Compactor::AlreadyCompacted, Compactor::EmptySummary => e
        runtime_output(e.message)
      rescue Cancellation::CancelledError
        raise
      rescue StandardError => e
        runtime_output("Compaction error: #{e.message}")
      end

      def render_compaction_summary(summary)
        render_transcript_block("Assistant", summary)
      end

    end
  end
end
