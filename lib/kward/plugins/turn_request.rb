require "securerandom"

module Kward
  # Immutable, host-dispatched system instructions for one session turn.
  # Historical records retain the instructions for display, not model replay.
  class PluginTurnRequest
    MAX_SYSTEM_BYTES = 65_536

    attr_reader :system, :command, :plugin_id, :id

    def initialize(system:, command:, plugin_id: nil, id: SecureRandom.uuid)
      unless system.is_a?(String) && system.valid_encoding? && !system.strip.empty? && system.bytesize <= MAX_SYSTEM_BYTES
        raise ArgumentError, "System instructions must be nonblank text of at most #{MAX_SYSTEM_BYTES} bytes"
      end

      @system = system.dup.freeze
      @command = command.to_s.dup.freeze
      @plugin_id = plugin_id&.to_s&.dup&.freeze
      @id = id.to_s.dup.freeze
      freeze
    end

    def to_s
      "/#{command} #{system}"
    end

    def history_message
      {
        role: "user",
        content: "A plugin requested a system-instruction turn. Those instructions are not active in later turns.",
        display_content: to_s,
        plugin_system_turn: { id: id, command: command, plugin_id: plugin_id, system: system, scope: "turn" }
      }
    end
  end
end
