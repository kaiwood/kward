require "base64"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal control escape sequence builders.
  module TerminalSequences
    KEYBOARD_PROTOCOL_ENABLE = "\e[>25u".freeze
    KEYBOARD_PROTOCOL_RESTORE = "\e[<u".freeze
    BRACKETED_PASTE_ENABLE = "\e[?2004h".freeze
    BRACKETED_PASTE_RESTORE = "\e[?2004l".freeze
    BRACKETED_PASTE_START = "\e[200~".freeze
    BRACKETED_PASTE_END = "\e[201~".freeze
    SYNCHRONIZED_OUTPUT_ENABLE = "\e[?2026h".freeze
    SYNCHRONIZED_OUTPUT_DISABLE = "\e[?2026l".freeze
    CURSOR_SHOW = "\e[?25h".freeze
    CURSOR_HIDE = "\e[?25l".freeze
    CURSOR_SHAPE_DEFAULT = "\e[0 q".freeze
    CURSOR_SHAPE_BAR = "\e[6 q".freeze
    MOUSE_REPORTING_ENABLE = "\e[?1003h\e[?1006h".freeze
    MOUSE_REPORTING_DISABLE = "\e[?1006l\e[?1003l".freeze
    SGR_RESET = "\e[0m".freeze
    SGR_INVERSE = "\e[7m".freeze
    SGR_INVERSE_OFF = "\e[27m".freeze

    module_function

    def scroll_region(top, bottom)
      "\e[#{top};#{bottom}r"
    end

    def restore_scroll_region
      "\e[r"
    end

    def move_to(row, col)
      "\e[#{row};#{col}H"
    end

    def osc52(text)
      "\e]52;c;#{Base64.strict_encode64(text.to_s)}\a"
    end
  end
end
