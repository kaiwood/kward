require_relative "config_files"

module Kward
  module PromptCommands
    BUILTIN_RESERVED_COMMAND_NAMES = %w[exit quit new resume name clone export compact redraw settings login model openrouter/catalog reasoning status stats crew memory].freeze
    SLASH_COMMAND_PATTERN = %r{\A/(\S+)(?:\s+(.*))?\z}m

    module_function

    def parse(input)
      match = input.to_s.match(SLASH_COMMAND_PATTERN)
      return nil unless match

      [match[1], match[2].to_s]
    end

    def expand(input, templates: nil, reserved_commands: BUILTIN_RESERVED_COMMAND_NAMES)
      parsed = parse(input)
      return nil unless parsed

      command, arguments = parsed
      templates ||= ConfigFiles.prompt_templates(reserved_commands: reserved_commands)
      template = templates.find { |candidate| candidate.command == command }
      return nil unless template

      template.expand(arguments)
    end
  end
end
