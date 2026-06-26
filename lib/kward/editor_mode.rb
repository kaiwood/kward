# Namespace for the Kward CLI agent runtime.
module Kward
  # Normalizes built-in TUI file editor mode names.
  module EditorMode
    MODES = %w[modern emacs vibe].freeze
    DEFAULT = "modern".freeze
    LINE_NUMBER_MODES = %w[absolute relative].freeze
    DEFAULT_LINE_NUMBERS = "absolute".freeze

    module_function

    def normalize(value)
      text = value.to_s.downcase
      return DEFAULT if text == "default"
      return "vibe" if text == "vi"

      MODES.include?(text) ? text : DEFAULT
    end

    def normalize_line_numbers(value)
      text = value.to_s.downcase
      LINE_NUMBER_MODES.include?(text) ? text : DEFAULT_LINE_NUMBERS
    end
  end
end
