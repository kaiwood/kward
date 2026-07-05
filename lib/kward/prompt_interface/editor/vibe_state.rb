# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Modal Vibe editor state for one editor buffer.
    class VibeEditorState
      attr_accessor :mode, :pending, :command, :last_change, :last_find
      attr_accessor :last_visual_selection, :visual_block_insert
      attr_accessor :marks, :registers, :register_types, :macros, :recording_macro, :last_macro
      attr_accessor :kill_linewise, :previous_change_cursor, :jump_back_list, :jump_forward_list

      def initialize(editor_mode: "modern")
        @mode = editor_mode == "vibe" ? "normal" : nil
        @pending = ""
        @command = ""
        @last_change = nil
        @last_find = nil
        @last_visual_selection = nil
        @visual_block_insert = nil
        @marks = {}
        @registers = {}
        @register_types = {}
        @kill_linewise = false
        @previous_change_cursor = nil
        @jump_back_list = []
        @jump_forward_list = []
        @macros = {}
        @recording_macro = nil
        @last_macro = nil
      end

      def self.copy(other)
        state = new(editor_mode: other.mode ? "vibe" : "modern")
        state.mode = other.mode&.dup
        state.pending = other.pending.dup
        state.command = other.command.dup
        state.last_change = other.last_change&.dup
        state.last_find = other.last_find&.dup
        state.last_visual_selection = other.last_visual_selection&.dup
        state.visual_block_insert = other.visual_block_insert&.dup
        state.marks = other.marks.transform_values(&:dup)
        state.registers = other.registers.transform_values(&:dup)
        state.register_types = other.register_types.transform_values(&:dup)
        state.kill_linewise = other.kill_linewise
        state.previous_change_cursor = other.previous_change_cursor
        state.jump_back_list = other.jump_back_list.map(&:dup)
        state.jump_forward_list = other.jump_forward_list.map(&:dup)
        state.macros = other.macros.transform_values(&:dup)
        state.recording_macro = other.recording_macro
        state.last_macro = other.last_macro
        state
      end
    end
  end
end
