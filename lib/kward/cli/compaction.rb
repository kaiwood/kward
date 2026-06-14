# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # CLI slash-command helpers for manual context compaction.
    module CompactionCommands
      private

      def compact_context(agent, argument)
        result = Compactor.new(
          conversation: agent.conversation,
          client: @client,
          tool_result_summarizer: lambda { |tool_call, content| tool_result_summary(tool_call, content) }
        ).compact(custom_instructions: argument)
        @prompt.say("\nCompacted context: #{result.old_message_count} messages -> #{result.new_message_count} messages.\n")
        render_transcript_block("Assistant", result.summary)
      rescue Compactor::NothingToCompact, Compactor::AlreadyCompacted, Compactor::EmptySummary => e
        @prompt.say("\n#{e.message}\n")
      rescue StandardError => e
        @prompt.say("\nCompaction error: #{e.message}\n")
      end

    end
  end
end
