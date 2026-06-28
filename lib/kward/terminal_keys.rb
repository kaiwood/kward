# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal input key byte sequences grouped by semantic key.
  module TerminalKeys
    RETURN = ["\n", "\r"].freeze
    BACKSPACE = ["\b", "\x7F"].freeze
    TAB = ["\t", "\e[9u", "\e[9;1u", "\e[27;1;9~"].freeze

    LEFT = ["\e[D", "\eOD"].freeze
    RIGHT = ["\e[C", "\eOC"].freeze
    UP = ["\e[A", "\eOA"].freeze
    DOWN = ["\e[B", "\eOB"].freeze
    HOME = ["\e[H", "\eOH", "\e[1~", "\e[7~"].freeze
    END_KEY = ["\e[F", "\eOF", "\e[4~", "\e[8~"].freeze
    DELETE = ["\e[3~"].freeze
    PAGE_UP = ["\e[5~"].freeze
    PAGE_DOWN = ["\e[6~"].freeze

    SHIFT_TAB = ["\e[Z", "\e[1;2Z", "\e[9;2u", "\e[27;2;9~", "\e[1;2I"].freeze
    CTRL_TAB = ["\e[9;5u", "\e[27;5;9~", "\e[1;5I"].freeze
    CTRL_SHIFT_TAB = ["\e[9;6u", "\e[27;6;9~", "\e[1;6I", "\e[1;6Z"].freeze
    SHIFT_ENTER = ["\e[13;2u", "\e[13;2~", "\e[27;2;13~", "\e\r", "\e\n"].freeze

    ALT_LEFT = ["\e[1;3D", "\e[3D"].freeze
    ALT_RIGHT = ["\e[1;3C", "\e[3C"].freeze
    ALT_UP = ["\e[1;3A", "\e[3A"].freeze
    ALT_DOWN = ["\e[1;3B", "\e[3B"].freeze

    SHIFT_LEFT = ["\e[1;2D", "\e[2D"].freeze
    SHIFT_RIGHT = ["\e[1;2C", "\e[2C"].freeze
    SHIFT_UP = ["\e[1;2A", "\e[2A"].freeze
    SHIFT_DOWN = ["\e[1;2B", "\e[2B"].freeze

    CTRL_LEFT = ["\e[1;5D", "\e[5D"].freeze
    CTRL_RIGHT = ["\e[1;5C", "\e[5C"].freeze
    CTRL_UP = ["\e[1;5A", "\e[5A"].freeze
    CTRL_DOWN = ["\e[1;5B", "\e[5B"].freeze

    ALT_SHIFT_LEFT = ["\e[1;4D", "\e[4D"].freeze
    ALT_SHIFT_RIGHT = ["\e[1;4C", "\e[4C"].freeze
    ALT_SHIFT_UP = ["\e[1;4A", "\e[4A"].freeze
    ALT_SHIFT_DOWN = ["\e[1;4B", "\e[4B"].freeze

    CTRL_SHIFT_RIGHT = ["\e[1;6C", "\e[6C"].freeze
    CTRL_SHIFT_UP = ["\e[1;6A", "\e[6A"].freeze
    CTRL_SHIFT_DOWN = ["\e[1;6B", "\e[6B"].freeze

    CTRL_T_CSI_U = "\e[116;5u".freeze
    CTRL_W_CSI_U = "\e[119;5u".freeze
    CTRL_NUMBER_TAB_PATTERN = /\A\e\[((?:49)|(?:5[0-7]));5u\z/.freeze

    CSI_U_PATTERN = /\A\e\[(\d+)((?:;[\d:]*)*)u/.freeze
    MODIFIED_CURSOR_PATTERN = /\A\e\[(\d+);(\d+)([CDFH])\z/.freeze
    MODIFIED_DELETE_PATTERN = /\A\e\[3;(\d+)~\z/.freeze
    UP_PATTERN = /\A\e\[[0-9;:]*A\z/.freeze
    DOWN_PATTERN = /\A\e\[[0-9;:]*B\z/.freeze
    RIGHT_PATTERN = /\A\e\[[0-9;:]*C\z/.freeze
    LEFT_PATTERN = /\A\e\[[0-9;:]*D\z/.freeze
    CSI_KEY_PATTERN = /\A\e\[[0-9;:]*[A-Za-z~]/.freeze
    SS3_KEY_PATTERN = /\A\eO[A-Za-z]/.freeze
  end
end
