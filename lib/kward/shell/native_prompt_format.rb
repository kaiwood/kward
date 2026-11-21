require "etc"
require_relative "../terminal/locale_text"
require_relative "../terminal/sequences"

module Kward
  module NativeShell
    # Expand only known prompt escapes. Metadata is text, never format source
    # or terminal control data. Only styles generated here occupy zero cells.
    class PromptFormat
      ESCAPES = /(%(?:[FK]\{[^{}%]*\}|1~|[~d\/nm?#%fkbB]))/n.freeze
      COLORS = %w[black red green yellow blue magenta cyan white].freeze
      STYLES = { "%f" => [39], "%k" => [49], "%B" => [1], "%b" => [22] }.freeze

      def initialize(template, directory:, home:, status:, color:)
        @directory = directory.b
        @home = home.to_s.b
        @status = status
        @parts = template.b.split(ESCAPES).filter_map do |part|
          style = STYLES[part] || color_style(part)
          style ? (style if color) : expand(part)
        end
        @styled = @parts.any? { |part| part.is_a?(Array) }
      end

      def cells(encoding)
        @parts.flat_map do |part|
          if part.is_a?(Array)
            [[TerminalSequences.sgr(*part), 0]]
          else
            TerminalText.locale_cells(part.b.force_encoding(encoding).scrub)
          end
        end
      end

      def render(cells)
        text = cells.map(&:first).join
        @styled ? text + TerminalSequences::SGR_RESET : text
      end

      private

      def expand(part)
        case part
        when "%%" then "%"
        when "%d", "%/" then @directory
        when "%~" then abbreviated_directory
        when "%1~" then File.basename(abbreviated_directory)
        when "%n" then username
        when "%m" then Etc.uname.fetch(:nodename).split(".", 2).first.to_s
        when "%?" then @status.to_s
        when "%#" then Process.euid.zero? ? "#" : "%"
        else part
        end
      end

      def abbreviated_directory
        return @directory unless @home.start_with?("/")

        home = @home.sub(%r{/+\z}, "")
        return "~" if @directory == (home.empty? ? "/" : home)
        return @directory unless @directory.start_with?("#{home}/")

        "~#{@directory.delete_prefix(home)}"
      end

      def username
        Etc.getpwuid(Process.euid).name
      rescue ArgumentError
        Process.euid.to_s
      end

      def color_style(part)
        match = /\A%([FK])\{([^{}]*)\}\z/n.match(part)
        return unless match

        foreground = match[1] == "F"
        specification = match[2]
        if (index = COLORS.index(specification))
          [(foreground ? 30 : 40) + index]
        elsif specification.match?(/\A\d{1,3}\z/) && (index = specification.to_i) <= 255
          [foreground ? 38 : 48, 5, index]
        elsif specification.match?(/\A#[0-9a-fA-F]{6}\z/)
          [foreground ? 38 : 48, 2, *specification[1..].scan(/../).map(&:hex)]
        end
      end
    end
  end
end
