# Namespace for the Kward CLI agent runtime.
module Kward
  # ANSI SGR styling and terminal-text helpers.
  #
  # Terminal control output sequences live in `TerminalSequences`, and input key
  # sequences live in `TerminalKeys`. This module owns text-level concerns:
  # colorizing strings, stripping/sanitizing escape sequences, visible wrapping,
  # and lightweight Markdown rendering for terminal output.
  module ANSI
    SGR_PATTERN = /\e\[[0-9;:]*m/.freeze
    STYLES = {
      reset: 0,
      bold: 1,
      dim: 2,
      italic: 3,
      strikethrough: 9,
      red: 31,
      green: 32,
      yellow: 33,
      blue: 34,
      magenta: 35,
      cyan: 36,
      gray: 90,
      grey: 90,
      white: 97,
      primary_green: "38;2;138;160;106",
      bright_accent_green: "38;2;155;255;0",
      augen: "38;2;155;255;0",
      dark_forest_green: "38;2;78;88;53",
      stone: "38;2;196;192;178",
      metal_dark: "38;2;42;42;42",
      background: "38;2;22;24;22"
    }.freeze

    module_function

    def enabled?(output = $stdout, env: ENV)
      setting = env["KWARD_COLOR"].to_s.downcase
      return true if %w[always force forced true yes 1].include?(setting)
      return false if %w[never false no 0].include?(setting)
      return true if forced_color?(env)
      return false if disabled_color?(env)

      output.respond_to?(:tty?) && output.tty?
    end

    def colorize(text, *styles, enabled: enabled?)
      string = text.to_s
      return string unless enabled

      codes = styles.flatten.map { |style| STYLES.fetch(style, style) }.compact
      return string if codes.empty?

      "\e[#{codes.join(";")}m#{string}\e[0m"
    end

    def strip(text)
      strip_control_sequences(text)
    end

    # Removes terminal escape/control sequences while preserving visible text.
    def strip_control_sequences(text)
      scan_escape_tokens(text).each_with_object(+"") do |token, stripped|
        stripped << token[:text] unless token[:escape]
      end
    end

    # Drops unsafe terminal controls from transcript text while preserving SGR color.
    def sanitize_transcript(text)
      scan_escape_tokens(text).each_with_object(+"") do |token, sanitized|
        if token[:escape]
          sanitized << token[:text] if token[:text].match?(SGR_PATTERN)
        else
          sanitized << token[:text]
        end
      end
    end

    def wrap_visible(text, width)
      line_width = [width.to_i, 1].max
      rows = []
      current = +""
      visible_width = 0

      scan_escape_tokens(text).each do |token|
        if token[:escape]
          next unless token[:text].match?(SGR_PATTERN)

          if current.empty? && rows.any?
            rows[-1] << token[:text]
          else
            current << token[:text]
          end
          next
        end

        token[:text].each_char do |char|
          current << char
          visible_width += 1
          if visible_width >= line_width
            rows << current
            current = +""
            visible_width = 0
          end
        end
      end

      rows << current unless current.empty?
      rows
    end

    # Splits text into visible chunks and terminal escape sequence chunks.
    def scan_escape_tokens(text)
      string = text.to_s
      tokens = []
      index = 0
      while index < string.length
        if string[index] == "\e" && (escape = escape_sequence_at(string, index))
          tokens << { text: escape, escape: true }
          index += escape.length
          next
        end

        next_escape = string.index("\e", index) || string.length
        tokens << { text: string[index...next_escape], escape: false } if next_escape > index
        index = next_escape
      end
      tokens
    end

    def escape_sequence_at(string, index)
      chunk = string[index..]
      chunk.match(/\A\e\][^\a]*(?:\a|\e\\)/m)&.[](0) ||
        chunk.match(/\A\e[P_X^][\s\S]*?\e\\/m)&.[](0) ||
        chunk.match(/\A\e\[[0-9;:?]*[ -\/]*[@-~]/)&.[](0) ||
        chunk[0, 2]
    end

    def markdown(text, enabled: enabled?)
      string = text.to_s
      lines = string.lines(chomp: true)
      rendered = []
      in_fence = false

      lines.each do |line|
        if (match = line.match(/\A\s*```([^`]*)\s*\z/))
          if in_fence
            rendered << colorize("└" + "─" * 39, :gray, enabled: enabled)
            in_fence = false
          else
            language = match[1].to_s.strip
            label = language.empty? ? "code" : "code #{language}"
            rendered << colorize("┌─ #{label}", :gray, enabled: enabled)
            in_fence = true
          end
          next
        end

        if in_fence
          rendered << colorize("│ #{line}", :dim, enabled: enabled)
        else
          rendered << markdown_line(line, enabled: enabled)
        end
      end

      rendered << colorize("└" + "─" * 39, :gray, enabled: enabled) if in_fence
      rendered.join("\n") + (string.end_with?("\n") ? "\n" : "")
    end

    # String wrapper that strips ANSI escape sequences while preserving visible text operations.
    class MarkdownStream
      def initialize(enabled: ANSI.enabled?)
        @enabled = enabled
        @pending = +""
        @in_fence = false
      end

      def render(delta, final: false)
        text = delta.to_s
        return ANSI.markdown(text, enabled: @enabled) if fast_markdown?(text, final)

        @pending << text
        rendered = +""
        while (match = @pending.match(/\r\n|\r|\n/))
          line = @pending[0...match.begin(0)]
          @pending = @pending[(match.end(0))..] || +""
          rendered << render_line(line) << "\n"
        end

        if final && !@pending.empty?
          rendered << render_line(@pending)
          @pending.clear
        end

        if final && @in_fence
          rendered << "\n" unless rendered.empty? || rendered.end_with?("\n")
          rendered << ANSI.colorize("└" + "─" * 39, :gray, enabled: @enabled)
          @in_fence = false
        end

        rendered
      end

      private

      def fast_markdown?(text, final)
        !final && !@in_fence && @pending.empty? && !text.match?(/[`*~_\[\]>]/)
      end

      def render_line(line)
        if (match = line.match(/\A\s*```([^`]*)\s*\z/))
          if @in_fence
            @in_fence = false
            ANSI.colorize("└" + "─" * 39, :gray, enabled: @enabled)
          else
            language = match[1].to_s.strip
            label = language.empty? ? "code" : "code #{language}"
            @in_fence = true
            ANSI.colorize("┌─ #{label}", :gray, enabled: @enabled)
          end
        elsif @in_fence
          ANSI.colorize("│ #{line}", :dim, enabled: @enabled)
        else
          ANSI.markdown_line(line, enabled: @enabled)
        end
      end
    end

    def markdown_line(line, enabled: enabled?)
      if (match = line.match(/\A(\#{1,6}\s+)(.+)\z/))
        markdown_heading(match[1], match[2], enabled: enabled)
      elsif (match = line.match(/\A(\s*)[-*]\s+\[([ xX])\]\s+(.+)\z/))
        task_list_item(match[1], match[2], match[3], enabled: enabled)
      elsif (match = line.match(/\A>\s?(.*)\z/))
        blockquote(match[1], enabled: enabled)
      else
        inline_markdown(line, enabled: enabled)
      end
    end

    def markdown_heading(marker, text, enabled: enabled?)
      "#{marker}#{colorize(text, :bold, enabled: enabled)}"
    end

    def task_list_item(indent, marker, text, enabled: enabled?)
      checked = marker.downcase == "x"
      box = checked ? colorize("☑", :green, enabled: enabled) : colorize("☐", :gray, enabled: enabled)
      "#{indent}#{box} #{inline_markdown(text, enabled: enabled)}"
    end

    def blockquote(text, enabled: enabled?)
      "#{colorize("│", :gray, enabled: enabled)} #{inline_markdown(text, enabled: enabled)}"
    end

    def inline_markdown(line, enabled: enabled?)
      line.to_s.split(/(`[^`\n]+`)/).map do |part|
        if part.start_with?("`") && part.end_with?("`") && part.length > 1
          "`#{colorize(part[1...-1], :dim, enabled: enabled)}`"
        else
          inline_links(part, enabled: enabled)
        end
      end.join
    end

    def inline_links(text, enabled: enabled?)
      text.split(/(\[[^\n\]]+\]\([^)\s]+\))/).map do |part|
        if (match = part.match(/\A\[([^\n\]]+)\]\(([^)\s]+)\)\z/))
          "#{colorize(match[1], :cyan, enabled: enabled)} (#{colorize(match[2], :dim, enabled: enabled)})"
        else
          inline_emphasis(part, enabled: enabled)
        end
      end.join
    end

    def inline_emphasis(text, enabled: enabled?)
      rendered = inline_bold(text, enabled: enabled)
      rendered = inline_strikethrough(rendered, enabled: enabled)
      inline_italic(rendered, enabled: enabled)
    end

    def inline_bold(text, enabled: enabled?)
      text.gsub(/\*\*([^\n]+?)\*\*/) do
        colorize(Regexp.last_match(1), :bold, enabled: enabled)
      end
    end

    def inline_strikethrough(text, enabled: enabled?)
      text.gsub(/~~([^\n]+?)~~/) do
        colorize(Regexp.last_match(1), :strikethrough, enabled: enabled)
      end
    end

    def inline_italic(text, enabled: enabled?)
      rendered = text.gsub(/(^|[\s\(\[{])\*([^*\n]+?)\*(?=$|[\s\)\]},.!?:;])/) do
        "#{Regexp.last_match(1)}#{colorize(Regexp.last_match(2), :italic, enabled: enabled)}"
      end
      rendered.gsub(/(^|[\s\(\[{])_([^_\n]+?)_(?=$|[\s\)\]},.!?:;])/) do
        "#{Regexp.last_match(1)}#{colorize(Regexp.last_match(2), :italic, enabled: enabled)}"
      end
    end

    def inline_code(line, enabled: enabled?)
      inline_markdown(line, enabled: enabled)
    end

    def forced_color?(env)
      force_color = env["FORCE_COLOR"]
      clicolor_force = env["CLICOLOR_FORCE"]
      (force_color && force_color != "0") || (clicolor_force && clicolor_force != "0")
    end

    def disabled_color?(env)
      return true if env.key?("NO_COLOR") && !env["NO_COLOR"].to_s.empty?
      return true if env["CLICOLOR"] == "0"

      env["TERM"] == "dumb"
    end
  end
end
