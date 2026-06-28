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
      RUBY_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|:[a-zA-Z_]\w*[!?=]?|\b\d+(?:\.\d+)?\b|\b[A-Z]\w*\b|\b(?:#{Regexp.union(RUBY_KEYWORDS)})\b)/.freeze
      MARKDOWN_PATTERN = /(`[^`\n]+`|!?\[[^\]\n]+\]\([^\)\n]+\)|(?:\*\*|__)[^\n]+?(?:\*\*|__)|(?:\*|_)[^\n]+?(?:\*|_))/.freeze
      HTML_PATTERN = /(<!--.*?-->|<\/?[A-Za-z][^>]*>|\b[A-Za-z_:-]+(?=\=)|"[^"]*"|'[^']*')/.freeze
      CSS_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|#[0-9a-fA-F]{3,8}\b|\.[A-Za-z_-][\w-]*|#[A-Za-z_-][\w-]*|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms)?\b|[A-Za-z_-][\w-]*(?=\s*:)|@[A-Za-z_-][\w-]*)/.freeze
      JSON_PATTERN = /("(?:\\.|[^"\\])*"(?=\s*:)|"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)/.freeze
      YAML_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:true|false|null|yes|no|on|off)\b|\b\d+(?:\.\d+)?\b|[A-Za-z0-9_-]+(?=\s*:))/.freeze
      SQL_PATTERN = /("(?:\\.|[^"\\])*"|'(?:''|[^'])*'|--.*|\b\d+(?:\.\d+)?\b|\b(?:SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|ON|INSERT|INTO|UPDATE|DELETE|CREATE|ALTER|DROP|TABLE|VIEW|INDEX|VALUES|SET|AND|OR|NOT|NULL|IS|AS|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|DISTINCT|UNION|ALL|CASE|WHEN|THEN|ELSE|END|PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|TRUE|FALSE)\b)/i.freeze
      GENERIC_STRING_NUMBER_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b)/.freeze

      LANGUAGE_DEFINITIONS = {
        javascript: {
          extensions: %w[.js .jsx .mjs .cjs],
          keywords: %w[async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield]
        },
        typescript: {
          extensions: %w[.ts .tsx],
          keywords: %w[abstract any as async await boolean break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function if implements import in infer instanceof interface is keyof let module namespace never new null number object of private protected public readonly return static string super switch symbol this throw true try type typeof undefined unknown var void while with yield]
        },
        shell: {
          extensions: %w[.sh .bash .zsh .fish],
          filenames: %w[.bashrc .bash_profile .zshrc .profile],
          line_comment: "#",
          keywords: %w[if then else elif fi for while until do done case esac function in select time coproc true false]
        },
        crystal: {
          extensions: %w[.cr],
          line_comment: "#",
          keywords: %w[if unless while for do end enum struct macro union lib annotation def class module case begin until else elsif ensure rescue]
        },
        elixir: {
          extensions: %w[.ex .exs],
          line_comment: "#",
          keywords: %w[def defp defmodule defprotocol defimpl defmacro do end fn case cond if unless try receive rescue after else true false nil]
        },
        julia: {
          extensions: %w[.jl],
          line_comment: "#",
          keywords: %w[begin if while for try let quote function macro module baremodule struct mutable abstract primitive type do end else elseif catch finally true false nothing]
        },
        makefile: {
          filenames: %w[Makefile makefile GNUmakefile],
          line_comment: "#",
          keywords: %w[ifeq ifneq ifdef ifndef else endif include define endef export unexport override]
        },
        python: {
          extensions: %w[.py .pyw],
          line_comment: "#",
          keywords: %w[and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield]
        },
        go: {
          extensions: %w[.go],
          keywords: %w[break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var]
        },
        rust: {
          extensions: %w[.rs],
          keywords: %w[as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while]
        },
        java: {
          extensions: %w[.java],
          keywords: %w[abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for if implements import instanceof int interface long native new null package private protected public return short static strictfp super switch synchronized this throw throws transient true try void volatile while]
        },
        csharp: {
          extensions: %w[.cs],
          keywords: %w[abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await]
        },
        c: {
          extensions: %w[.c .h],
          keywords: %w[auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while]
        },
        cpp: {
          extensions: %w[.cc .cpp .cxx .hpp .hh .hxx],
          keywords: %w[alignas alignof and asm auto bool break case catch char char16_t char32_t class const constexpr const_cast continue decltype default delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator or private protected public register reinterpret_cast return short signed sizeof static static_assert static_cast struct switch template this throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while]
        },
        swift: {
          extensions: %w[.swift],
          keywords: %w[as associatedtype break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is let nil open operator private protocol public repeat rethrows return self Self static struct subscript super switch throw throws true try typealias var where while]
        },
        kotlin: {
          extensions: %w[.kt .kts],
          keywords: %w[as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg]
        },
        lua: {
          extensions: %w[.lua],
          line_comment: "--",
          keywords: %w[and break do else elseif end false for function goto if in local nil not or repeat return then true until while]
        }
      }.freeze

      RUBY_FILENAMES = %w[Gemfile Rakefile Guardfile Capfile Thorfile Vagrantfile].freeze
      RUBY_EXTENSIONS = %w[.rb .rake .gemspec].freeze
      MARKDOWN_EXTENSIONS = %w[.md .markdown].freeze
      JSON_EXTENSIONS = %w[.json].freeze
      YAML_EXTENSIONS = %w[.yml .yaml].freeze
      HTML_EXTENSIONS = %w[.html .htm].freeze
      CSS_EXTENSIONS = %w[.css].freeze
      SCSS_EXTENSIONS = %w[.scss].freeze
      SQL_EXTENSIONS = %w[.sql].freeze

      private

      def editor_highlight_line(line, line_index = nil)
        return line.to_s unless @color_enabled

        case editor_syntax_language
        when :ruby
          editor_highlight_ruby(line, line_index)
        when :markdown
          editor_highlight_markdown(line)
        when :json
          editor_highlight_json(line)
        when :yaml
          editor_highlight_yaml(line)
        when :html
          editor_highlight_html(line)
        when :css, :scss
          editor_highlight_css(line)
        when :sql
          editor_highlight_sql(line)
        else
          editor_highlight_generic(line, editor_syntax_language, line_index)
        end
      end

      def editor_syntax_language
        return nil unless @editor_state
        return @editor_state.language if @editor_state.language

        path = @editor_state.path || @editor_state.display_path
        @editor_syntax_language_path ||= nil
        if @editor_syntax_language_path != path
          @editor_syntax_language_path = path
          @editor_syntax_language = editor_detect_syntax_language(path)
        end
        @editor_syntax_language
      end

      def editor_detect_syntax_language(path)
        basename = File.basename(path.to_s)
        extension = File.extname(basename).downcase
        return :ruby if RUBY_FILENAMES.include?(basename) || RUBY_EXTENSIONS.include?(extension)
        return :markdown if MARKDOWN_EXTENSIONS.include?(extension)
        return :json if JSON_EXTENSIONS.include?(extension)
        return :yaml if YAML_EXTENSIONS.include?(extension)
        return :html if HTML_EXTENSIONS.include?(extension)
        return :scss if SCSS_EXTENSIONS.include?(extension)
        return :css if CSS_EXTENSIONS.include?(extension)
        return :sql if SQL_EXTENSIONS.include?(extension)

        LANGUAGE_DEFINITIONS.each do |language, definition|
          return language if definition.fetch(:extensions, []).include?(extension)
          return language if definition.fetch(:filenames, []).include?(basename)
        end
        nil
      end

      def editor_highlight_ruby(line, line_index = nil)
        text = line.to_s
        return colored(text, :gray) if editor_ruby_block_comment_line?(line_index)

        comment_index = editor_comment_index(text, "#")
        return editor_highlight_ruby_code(text) unless comment_index

        editor_highlight_ruby_code(text[0...comment_index].to_s) + colored(text[comment_index..].to_s, :gray)
      end

      def editor_highlight_ruby_code(line)
        line.to_s.gsub(RUBY_PATTERN) do |token|
          editor_highlight_ruby_token(token)
        end
      end

      def editor_ruby_block_comment_line?(line_index)
        return false unless line_index && @editor_state

        in_comment = false
        @editor_state.lines.first(line_index.to_i + 1).each_with_index do |line, index|
          starts_block = line.match?(/\A=begin\b/)
          ends_block = line.match?(/\A=end\b/)
          return true if index == line_index && (in_comment || starts_block || ends_block)

          in_comment = true if starts_block
          in_comment = false if ends_block
        end
        false
      end

      def editor_highlight_ruby_token(token)
        if token.start_with?("\"", "'")
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

      def editor_highlight_generic(line, language, line_index = nil)
        definition = LANGUAGE_DEFINITIONS[language]
        return line.to_s unless definition

        text = line.to_s
        return colored(text, :gray) if editor_c_style_block_comment_line?(line_index)

        marker = definition[:line_comment] || "//"
        comment_index = editor_comment_index(text, marker)
        return editor_highlight_generic_code(text, definition[:keywords]) unless comment_index

        editor_highlight_generic_code(text[0...comment_index].to_s, definition[:keywords]) + colored(text[comment_index..].to_s, :gray)
      end

      def editor_highlight_generic_code(line, keywords)
        pattern = editor_generic_pattern(keywords)
        line.to_s.gsub(pattern) do |token|
          editor_highlight_generic_token(token, keywords)
        end
      end

      def editor_generic_pattern(keywords)
        /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|\b[A-Z]\w*\b|\b(?:#{Regexp.union(keywords)})\b)/
      end

      def editor_highlight_generic_token(token, keywords)
        if token.start_with?("\"", "'", "`")
          colored(token, :green)
        elsif token.match?(/\A\d/)
          colored(token, :magenta)
        elsif keywords.include?(token)
          colored(token, :blue)
        elsif token.match?(/\A[A-Z]/)
          colored(token, :yellow)
        else
          token
        end
      end

      def editor_c_style_block_comment_line?(line_index)
        return false unless line_index && @editor_state

        in_comment = false
        @editor_state.lines.first(line_index.to_i + 1).each_with_index do |line, index|
          starts_block = editor_comment_index(line, "/*")
          ends_block = in_comment && line.include?("*/")
          return true if index == line_index && (in_comment || starts_block)

          in_comment = true if starts_block && !line[starts_block..].to_s.include?("*/")
          in_comment = false if ends_block
        end
        false
      end

      def editor_comment_index(line, marker)
        quote = nil
        escaped = false
        text = line.to_s
        index = 0
        while index < text.length
          char = text[index]
          if quote
            if escaped
              escaped = false
            elsif char == "\\"
              escaped = true
            elsif char == quote
              quote = nil
            end
          elsif char == "\"" || char == "'" || char == "`"
            quote = char
          elsif text[index, marker.length] == marker
            return index
          end
          index += 1
        end
        nil
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

      def editor_highlight_json(line)
        line.to_s.gsub(JSON_PATTERN) do |token|
          if token.start_with?("\"") && token.end_with?("\"")
            Regexp.last_match.post_match.match?(/\A\s*:/) ? colored(token, :cyan) : colored(token, :green)
          elsif token.match?(/\A-?\d/)
            colored(token, :magenta)
          else
            colored(token, :blue)
          end
        end
      end

      def editor_highlight_yaml(line)
        text = line.to_s
        comment_index = editor_comment_index(text, "#")
        highlighted = if comment_index
                        editor_highlight_yaml_code(text[0...comment_index].to_s) + colored(text[comment_index..].to_s, :gray)
                      else
                        editor_highlight_yaml_code(text)
                      end
        highlighted
      end

      def editor_highlight_yaml_code(line)
        line.to_s.gsub(YAML_PATTERN) do |token|
          if Regexp.last_match.post_match.match?(/\A\s*:/)
            colored(token, :cyan)
          elsif token.start_with?("\"", "'")
            colored(token, :green)
          elsif token.match?(/\A\d/)
            colored(token, :magenta)
          else
            colored(token, :blue)
          end
        end
      end

      def editor_highlight_html(line)
        line.to_s.gsub(HTML_PATTERN) do |token|
          if token.start_with?("<!--")
            colored(token, :gray)
          elsif token.start_with?("<")
            colored(token, :blue)
          elsif token.start_with?("\"", "'")
            colored(token, :green)
          else
            colored(token, :cyan)
          end
        end
      end

      def editor_highlight_css(line)
        text = line.to_s
        return colored(text, :gray) if text.strip.start_with?("/*")

        text.gsub(CSS_PATTERN) do |token|
          if token.start_with?("\"", "'")
            colored(token, :green)
          elsif token.start_with?("#") && token.match?(/\A#[0-9a-fA-F]/)
            colored(token, :magenta)
          elsif token.start_with?(".", "#", "@")
            colored(token, :cyan)
          elsif token.match?(/\A\d/)
            colored(token, :magenta)
          else
            colored(token, :blue)
          end
        end
      end

      def editor_highlight_sql(line)
        line.to_s.gsub(SQL_PATTERN) do |token|
          if token.start_with?("--")
            colored(token, :gray)
          elsif token.start_with?("\"", "'")
            colored(token, :green)
          elsif token.match?(/\A\d/)
            colored(token, :magenta)
          else
            colored(token, :blue)
          end
        end
      end
    end
  end
end
