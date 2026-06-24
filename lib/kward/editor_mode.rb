# Namespace for the Kward CLI agent runtime.
module Kward
  # Normalizes built-in TUI file editor mode names.
  module EditorMode
    MODES = %w[modern emacs vi].freeze
    DEFAULT = "modern".freeze

    module_function

    def normalize(value)
      text = value.to_s.downcase
      return DEFAULT if text == "default"

      MODES.include?(text) ? text : DEFAULT
    end
  end
end
