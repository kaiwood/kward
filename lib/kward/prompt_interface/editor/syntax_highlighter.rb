# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Lightweight line-oriented syntax highlighting for the built-in editor.
    module EditorSyntaxHighlighter
      RUBY_KEYWORDS = %w[
        BEGIN END alias and begin break case class def defined? do else elsif end ensure
        false for if in module next nil not or redo rescue retry return self super then true
        undef unless until when while yield
      ].freeze
      RUBY_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|#. *|#.*|:[a-zA-Z_]\w*[!?=]?|\b\d+(?:\.\d+)?\b|\b[A-Z]\w*\b|\b(?:#{Regexp.union(RUBY_KEYWORDS)})\b)/.freeze
      MARKDOWN_PATTERN = /(`[^`\n]+`|!?\[[^\]\n]+\]\([^\)\n]+\)|(?:\*\*|__)[^\n]+?(?:\*\*|__)|(?:\*|_)[^\n]+?(?:\*|_))/.freeze
      RUBY_FILENAMES = %w[Gemfile Rakefile Guardfile Capfile Thorfile Vagrantfile].freeze
      RUBY_EXTENSIONS = %w[.rb .rake .gemspec].freeze
      MARKDOWN_EXTENSIONS = %w[.md .markdown].freeze

      private

      def editor_highlight_line(line)
        return line.to_s unless @color_enabled

        case editor_syntax_language
        when :ruby
          editor_highlight_ruby(line)
        when :markdown
          editor_highlight_markdown(line)
        else
          line.to_s
        end
      end

      def editor_syntax_language
        return nil unless @editor_state

        @editor_syntax_language_path ||= nil
        if @editor_syntax_language_path != @editor_state.path
          @editor_syntax_language_path = @editor_state.path
          @editor_syntax_language = editor_detect_syntax_language(@editor_state.path)
        end
        @editor_syntax_language
      end

      def editor_detect_syntax_language(path)
        basename = File.basename(path.to_s)
        extension = File.extname(basename).downcase
        return :ruby if RUBY_FILENAMES.include?(basename) || RUBY_EXTENSIONS.include?(extension)
        return :markdown if MARKDOWN_EXTENSIONS.include?(extension)

        nil
      end

      def editor_highlight_ruby(line)
        line.to_s.gsub(RUBY_PATTERN) do |token|
          editor_highlight_ruby_token(token)
        end
      end

      def editor_highlight_ruby_token(token)
        if token.start_with?("#")
          colored(token, :gray)
        elsif token.start_with?("\"", "'")
          colored(token, :green)
        elsif token.start_with?(":")
          colored(token, :cyan)
        elsif token.match?(/\A\d/)
          colored(token, :magenta)
        elsif RUBY_KEYWORDS.include?(token)
          colored(token, :blue)
        elsif token.match?(/\A[A-Z]/)
          colored(token, :yellow)
        else
          token
        end
      end

      def editor_highlight_markdown(line)
        text = line.to_s
        return editor_highlight_markdown_heading(text) if text.match?(/\A\s{0,3}[#]{1,6}\s/)
        return editor_highlight_markdown_fence(text) if text.match?(/\A\s*```/)
        return editor_highlight_markdown_blockquote(text) if text.match?(/\A\s*>/)
        return editor_highlight_markdown_list(text) if text.match?(/\A\s*(?:[-*+]\s+|\d+\.\s+)/)

        editor_highlight_markdown_inline(text)
      end

      def editor_highlight_markdown_heading(line)
        line.sub(/\A(\s{0,3}[#]{1,6}\s+)(.*)\z/) do
          "#{colored(Regexp.last_match(1), :cyan)}#{colored(Regexp.last_match(2), :bold)}"
        end
      end

      def editor_highlight_markdown_fence(line)
        colored(line, :gray)
      end

      def editor_highlight_markdown_blockquote(line)
        line.sub(/\A(\s*>\s?)(.*)\z/) do
          "#{colored(Regexp.last_match(1), :gray)}#{editor_highlight_markdown_inline(Regexp.last_match(2))}"
        end
      end

      def editor_highlight_markdown_list(line)
        line.sub(/\A(\s*(?:[-*+]\s+|\d+\.\s+))(.*)\z/) do
          "#{colored(Regexp.last_match(1), :cyan)}#{editor_highlight_markdown_inline(Regexp.last_match(2))}"
        end
      end

      def editor_highlight_markdown_inline(line)
        line.to_s.gsub(MARKDOWN_PATTERN) do |token|
          if token.start_with?("`")
            colored(token, :dim)
          elsif token.start_with?("[", "![")
            colored(token, :blue)
          else
            colored(token, :bold)
          end
        end
      end
    end
  end
end
