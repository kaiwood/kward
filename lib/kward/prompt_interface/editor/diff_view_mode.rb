# Namespace for the Kward CLI agent runtime.
module Kward
  # Normalizes and resolves the integrated diff viewer display mode.
  module DiffViewMode
    AUTO = "auto"
    UNIFIED = "unified"
    SIDE_BY_SIDE = "side_by_side"
    MODES = [AUTO, UNIFIED, SIDE_BY_SIDE].freeze
    SIDE_BY_SIDE_MIN_WIDTH = 120

    module_function

    def normalize(value)
      text = value.to_s.downcase.tr("-", "_")
      MODES.include?(text) ? text : AUTO
    end

    def label(value)
      case normalize(value)
      when SIDE_BY_SIDE
        "side-by-side"
      when UNIFIED
        "unified"
      else
        "auto"
      end
    end

    def resolve(value, terminal_width: nil)
      mode = normalize(value)
      return mode unless mode == AUTO

      terminal_width.to_i >= SIDE_BY_SIDE_MIN_WIDTH ? SIDE_BY_SIDE : UNIFIED
    end
  end
end
