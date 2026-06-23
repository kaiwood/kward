# Namespace for the Kward CLI agent runtime.
module Kward
  # Normalizes built-in TUI file editor mode names.
  module EditorMode
    MODES = %w[nano emacs vi].freeze
    DEFAULT = "nano".freeze

    module_function

    def normalize(value)
      text = value.to_s.downcase
      return DEFAULT if text == "default"

      MODES.include?(text) ? text : DEFAULT
    end
  end
end
