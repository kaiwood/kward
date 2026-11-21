# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal control escape sequence builders.
  module TerminalSequences
    ALERT = "\a".freeze
    CARRIAGE_RETURN = "\r".freeze
    ERASE_LINE_END = "\e[K".freeze
    KEYBOARD_PROTOCOL_ENABLE = "\e[>25u".freeze
    KEYBOARD_PROTOCOL_RESTORE = "\e[<u".freeze
    KEYBOARD_PROTOCOL_SET = "\e[=25u".freeze
    # Cancel incomplete controls before restoring the composer's terminal baseline.
    CONTROL_SEQUENCE_CANCEL = "\x18\e\\".freeze
    COMPOSER_MODES_RESTORE = (
      "\e[?2026l\e[?1049l\e[?1047l\e[?47l" +
      "\e[?1l\e>\e[?1004l\e[>4;0m" +
      "\e[?1000l\e[?1002l\e[?1003l\e[?1005l\e[?1006l\e[?1015l" +
      "\e[?6l\e[?7h\e[4l"
    ).freeze
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

    KITTY_GRAPHICS_PREFIX = "\e_G".freeze
    KITTY_GRAPHICS_COMMAND = /\A\e_G(?:[A-Za-z]=[A-Za-z0-9+-]+(?:,[A-Za-z]=[A-Za-z0-9+-]+)*)?(?:;[A-Za-z0-9+\/=]*)?\e\\\z/.freeze
    DEVICE_QUERY = /\A\e\[(?:>?0?c|>0?q|\?u|[56]n|\?6n|1[468]t)\z/.freeze

    module_function

    def keyboard_mode_mutation?(sequence)
      sequence.match?(/\A\e\[[><=][0-9;]*u\z/) ||
        sequence.match?(/\A\e\[>4(?:;[0-9]*)?m\z/)
    end

    def keyboard_mode_reset?(sequence)
      return true if sequence == "\ec" || sequence == "\e[!p"

      match = sequence.match(/\A\e\[\?([0-9;]+)[hl]\z/)
      match && (match[1].split(";") & %w[47 1047 1049]).any?
    end

    def scroll_region(top, bottom)
      "\e[#{top};#{bottom}r"
    end

    def restore_scroll_region
      "\e[r"
    end

    def move_to(row, col)
      "\e[#{row};#{col}H"
    end

    def move_to_column(column)
      "\e[#{column}G"
    end

    def osc52(text)
      "\e]52;c;#{[text.to_s].pack("m0")}\a"
    end

    def kitty_graphics(data, image_id:, columns: nil, rows: nil, move_cursor: true)
      payload = data.to_s
      chunks = payload.scan(/.{1,4096}/m)
      chunks = [""] if chunks.empty?

      chunks.each_with_index.map do |chunk, index|
        more = index < chunks.length - 1 ? 1 : 0
        params = index.zero? ? ["a=T", "f=100", "t=d"] : []
        params << "i=#{image_id}" if index.zero? && image_id
        params << "c=#{columns.to_i}" if index.zero? && columns
        params << "r=#{rows.to_i}" if index.zero? && rows
        params << "C=1" if index.zero? && !move_cursor
        params << "q=2" if index == chunks.length - 1
        params << "m=#{more}"
        "\e_G#{params.join(",")};#{chunk}\e\\"
      end.join
    end

    def kitty_query(image_id = 31)
      "\e_Gi=#{image_id},s=1,v=1,a=q,t=d,f=24;AAAA\e\\"
    end

    def kitty_delete(image_id)
      "\e_Ga=d,d=I,i=#{image_id},q=2;\e\\"
    end

    def tmux_passthrough(sequence)
      "\ePtmux;#{sequence.to_s.gsub("\e", "\e\e")}\e\\"
    end

    def iterm2_image(data, name: nil, width: nil, height: nil)
      params = ["inline=1", "preserveAspectRatio=1"]
      params << "width=#{width}" if width
      params << "height=#{height}" if height
      params << "name=#{[File.basename(name)].pack("m0")}" if name
      "\e]1337;File=#{params.join(";")}:#{data}\a"
    end
  end
end
