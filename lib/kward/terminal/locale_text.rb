require "fiddle"

module Kward
  module TerminalText
    # Standalone native shells use a scoped libc locale rather than the TUI's
    # Unicode gem. Call only inside NativeShell::Locale.with; never setlocale.
    LOCALE_WCWIDTH = Fiddle::Function.new(Fiddle::Handle::DEFAULT["wcwidth"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)

    def self.locale_cells(text)
      text.each_char.map do |character|
        begin
          codepoint = character.encode(Encoding::UTF_8).ord
          width = LOCALE_WCWIDTH.call(codepoint)
          if codepoint < 32 || codepoint == 127
            ["^#{(codepoint ^ 64).chr}", 2]
          elsif width >= 0
            [character, width]
          else
            escaped = "\\u{#{codepoint.to_s(16)}}"
            [escaped, escaped.length]
          end
        rescue EncodingError
          escaped = character.bytes.map { |byte| format('\\x%02x', byte) }.join
          [escaped, escaped.length]
        end
      end
    end
  end
end
