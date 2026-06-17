# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive memory management commands mixed into the CLI frontend.
    module MemoryCommands
      private

      def memory_summarize_command?(argument)
        subcommand, = argument.to_s.strip.split(/\s+/, 2)
        ["summarize", "learn"].include?(subcommand)
      end

      def handle_memory_command(argument, agent)
        subcommand, rest = argument.to_s.strip.split(/\s+/, 2)
        manager = Memory::Manager.new
        case subcommand
        when "enable"
          manager.enable
          agent.conversation.refresh_system_message!
          runtime_output("Memory enabled.")
        when "disable"
          manager.disable
          agent.conversation.memory_context = nil
          agent.conversation.refresh_system_message!
          runtime_output("Memory disabled.")
        when "auto-summary"
          case rest.to_s.strip
          when "enable", "on"
            manager.auto_summary_enable
            runtime_output("Memory auto-summary enabled.")
          when "disable", "off"
            manager.auto_summary_disable
            runtime_output("Memory auto-summary disabled.")
          else
            runtime_output("Usage: /memory auto-summary enable|disable")
          end
        when "core"
          record = manager.add_core(unquote_argument(rest))
          runtime_output("Added core memory #{record["id"]}.")
        when "add"
          record = manager.add_soft(unquote_argument(rest), scope: "workspace:#{agent.conversation.workspace_root}")
          runtime_output("Added soft memory #{record["id"]}.")
        when "list"
          runtime_output(format_memory_list(manager.hierarchy(workspace_root: agent.conversation.workspace_root)))
        when "forget"
          forgotten = manager.forget_memory(rest.to_s.strip)
          runtime_output(forgotten ? "Forgot #{rest.to_s.strip}." : "No memory found for #{rest.to_s.strip}.")
        when "promote"
          record = manager.promote_memory(rest.to_s.strip)
          runtime_output("Promoted memory #{record["id"]}.")
        when "relax"
          record = manager.relax_core(rest.to_s.strip, workspace_root: agent.conversation.workspace_root)
          runtime_output("Relaxed memory #{record["id"]}.")
        when "inspect"
          runtime_output(JSON.pretty_generate(manager.inspect_memory))
        when "why"
          explanation = agent.conversation.last_memory_retrieval || manager.explain_retrieval
          runtime_output(format_memory_why(explanation))
        when "summarize", "learn"
          records = summarize_memory(agent.conversation, manager: manager)
          runtime_output("Learned #{records.length} soft #{records.length == 1 ? "memory" : "memories"}.")
        else
          runtime_output("Usage: /memory enable|disable|auto-summary enable|disable|core <text>|add <text>|list|forget <id>|promote <id>|relax <id>|inspect|why|summarize")
        end
      rescue StandardError => e
        runtime_output("Memory command failed: #{e.message}")
      end

      def summarize_memory(conversation, manager: Memory::Manager.new)
        records = manager.summarize_conversation(conversation, client: @client)
        @active_session&.update_memory_state(session_memories: conversation.session_memories, last_retrieval: conversation.last_memory_retrieval)
        records
      end

      def unquote_argument(text)
        value = text.to_s.strip
        value = value[1...-1] if value.length >= 2 && ((value.start_with?("\"") && value.end_with?("\"")) || (value.start_with?("'") && value.end_with?("'")))
        value
      end

      def format_memory_list(memories)
        sections = [
          ["Global Core Memories:", Array(memories["global_core"])],
          ["Workspace Core Memories:", Array(memories["workspace_core"])],
          ["Workspace Soft Memories:", Array(memories["workspace_soft"])]
        ]

        sections.flat_map do |heading, records|
          lines = [heading]
          records.each { |item| lines << "- #{item["id"]} [#{item["scope"]}] #{item["text"]}" }
          lines << "- none" if records.empty?
          lines
        end.join("\n")
      end

      def format_memory_why(explanation)
        reasons = Array(explanation["reasons"])
        return explanation["message"] || "No memories were retrieved." if reasons.empty?

        (["Memory retrieval reasons:"] + reasons.map { |item| "- #{item["id"]} (#{item["layer"]}, score #{item["score"]}): #{Array(item["reasons"]).join("; ")}" }).join("\n")
      end

      def prepare_memory_context(conversation, input)
        manager = Memory::Manager.new
        retrieval = manager.retrieve_relevant(input: input, workspace_root: conversation.workspace_root)
        conversation.last_memory_retrieval = retrieval
        conversation.memory_context = manager.memory_block(retrieval)
        conversation.refresh_system_message!
      rescue StandardError => e
        warn "Memory retrieval failed: #{e.message}"
        nil
      end

      def persist_memory_state(conversation)
        @active_session&.update_memory_state(session_memories: conversation.session_memories, last_retrieval: conversation.last_memory_retrieval)
      rescue StandardError
        nil
      end

      def auto_summarize_memory(conversation)
        manager = Memory::Manager.new
        return unless manager.enabled? && manager.auto_summary_enabled?

        summarize_memory(conversation, manager: manager)
      rescue StandardError => e
        warn "Memory auto-summary failed: #{e.message}"
        nil
      end

    end
  end
end
