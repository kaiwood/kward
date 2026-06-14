# Namespace for the Kward CLI agent runtime.
module Kward
  # Slash-command completion overlay behavior.
  class PromptInterface
    # Slash-command completion overlay support.
    module SlashOverlay
      private

      def reset_slash_selection
        @slash_selection_index = 0
      end

      def dismiss_slash_overlay
        return false unless slash_overlay_visible?

        @slash_overlay_dismissed_input = composer_input.dup
        reset_slash_selection
        true
      end

      def normalize_slash_commands(commands)
        commands.map do |command|
          {
            name: slash_command_value(command, :name).to_s,
            description: slash_command_value(command, :description).to_s,
            argument_hint: slash_command_value(command, :argument_hint).to_s
          }
        end.reject { |command| command[:name].empty? }.sort_by { |command| command[:name] }
      end

      def slash_command_value(command, key)
        return command[key] if command.respond_to?(:key?) && command.key?(key)
        return command[key.to_s] if command.respond_to?(:key?) && command.key?(key.to_s)
        return command.public_send(key) if command.respond_to?(key)

        ""
      end

      def slash_overlay_visible?
        composer_input.match?(%r{\A/[^\s/]*\z}) && @slash_overlay_dismissed_input != composer_input && !slash_overlay_matches.empty?
      end

      def slash_overlay_matches
        prefix = composer_input.delete_prefix("/").downcase
        @slash_commands.select { |command| command[:name].downcase.start_with?(prefix) }.first(8)
      end

      def selected_slash_command
        return nil unless slash_overlay_visible?

        matches = slash_overlay_matches
        return nil if matches.empty?

        matches[[@slash_selection_index, matches.length - 1].min]
      end

      def select_previous_slash_command
        matches = slash_overlay_matches
        return if matches.empty?

        @slash_selection_index = (@slash_selection_index - 1) % matches.length
      end

      def select_next_slash_command
        matches = slash_overlay_matches
        return if matches.empty?

        @slash_selection_index = (@slash_selection_index + 1) % matches.length
      end

      def complete_selected_slash_command
        command = selected_slash_command
        return false unless command

        replace_input("/#{command[:name]} ")
        reset_slash_selection
        true
      end

      def slash_overlay_rows(width, height: screen_height)
        return [] unless slash_overlay_visible?

        visible = visible_slash_overlay_matches(slash_overlay_matches, height: height)
        start_index = visible[:start]
        lines = visible[:commands].each_with_index.map do |command, offset|
          index = start_index + offset
          hint = command[:argument_hint].empty? ? "" : " #{command[:argument_hint]}"
          description = command[:description].empty? ? "" : " — #{command[:description]}"
          overlay_choice_line("/#{command[:name]}#{hint}#{description}", selected: index == @slash_selection_index)
        end
        overlay_card_rows("Slash commands", lines, width)
      end

      def visible_slash_overlay_matches(matches, height: screen_height)
        max_rows = [[height - 7, 1].max, 8].min
        start = [[@slash_selection_index - max_rows + 1, 0].max, [matches.length - max_rows, 0].max].min
        { start: start, commands: matches[start, max_rows] || [] }
      end

    end
  end
end
