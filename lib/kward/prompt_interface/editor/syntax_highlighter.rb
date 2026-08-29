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
      HTML_TAG_START_PATTERN = /<\/?[A-Za-z][\w:-]*/.freeze
      CSS_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|#[0-9a-fA-F]{3,8}\b|\.[A-Za-z_-][\w-]*|#[A-Za-z_-][\w-]*|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms)?\b|[A-Za-z_-][\w-]*(?=\s*:)|@[A-Za-z_-][\w-]*)/.freeze
      JSON_PATTERN = /("(?:\\.|[^"\\])*"(?=\s*:)|"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)/.freeze
      YAML_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:true|false|null|yes|no|on|off)\b|\b\d+(?:\.\d+)?\b|[A-Za-z0-9_-]+(?=\s*:))/.freeze
      SQL_PATTERN = /("(?:\\.|[^"\\])*"|'(?:''|[^'])*'|--.*|\b\d+(?:\.\d+)?\b|\b(?:SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|ON|INSERT|INTO|UPDATE|DELETE|CREATE|ALTER|DROP|TABLE|VIEW|INDEX|VALUES|SET|AND|OR|NOT|NULL|IS|AS|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|DISTINCT|UNION|ALL|CASE|WHEN|THEN|ELSE|END|PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|TRUE|FALSE)\b)/i.freeze
      GENERIC_STRING_NUMBER_PATTERN = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b)/.freeze
      ERB_OPEN_PATTERN = /<%[#=]?/.freeze
      ERB_CLOSE_PATTERN = /-?%>/.freeze

      LANGUAGE_DEFINITIONS = {
        javascript: {
          extensions: %w[.js .jsx .mjs .cjs],
          block_comment: true,
          keywords: %w[async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield]
        },
        typescript: {
          extensions: %w[.ts .tsx],
          block_comment: true,
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
          extensions: %w[.mk],
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
          block_comment: true,
          keywords: %w[break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var]
        },
        rust: {
          extensions: %w[.rs],
          block_comment: true,
          keywords: %w[as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while]
        },
        java: {
          extensions: %w[.java],
          block_comment: true,
          keywords: %w[abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for if implements import instanceof int interface long native new null package private protected public return short static strictfp super switch synchronized this throw throws transient true try void volatile while]
        },
        csharp: {
          extensions: %w[.cs],
          block_comment: true,
          keywords: %w[abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await]
        },
        c: {
          extensions: %w[.c .h],
          block_comment: true,
          keywords: %w[auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while]
        },
        cpp: {
          extensions: %w[.cc .cpp .cxx .hpp .hh .hxx],
          block_comment: true,
          keywords: %w[alignas alignof and asm auto bool break case catch char char16_t char32_t class const constexpr const_cast continue decltype default delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator or private protected public register reinterpret_cast return short signed sizeof static static_assert static_cast struct switch template this throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while]
        },
        swift: {
          extensions: %w[.swift],
          block_comment: true,
          keywords: %w[as associatedtype break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is let nil open operator private protocol public repeat rethrows return self Self static struct subscript super switch throw throws true try typealias var where while]
        },
        kotlin: {
          extensions: %w[.kt .kts],
          block_comment: true,
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
      ERB_EXTENSIONS = %w[.erb].freeze
      CSS_EXTENSIONS = %w[.css].freeze
      SCSS_EXTENSIONS = %w[.scss].freeze
      SQL_EXTENSIONS = %w[.sql].freeze

      private

      def editor_highlight_line(line, line_index = nil)
        return line.to_s unless @color_enabled

        if editor_syntax_language == :markdown
          editor_highlight_markdown(line, line_index)
        else
          editor_highlight_language_line(line, editor_syntax_language, line_index)
        end
      end

      def editor_highlight_language_line(line, language, line_index = nil)
        case language
        when :ruby
          editor_highlight_ruby(line, line_index)
        when :json
          editor_highlight_json(line)
        when :yaml
          editor_highlight_yaml(line)
        when :html
          editor_highlight_html(line)
        when :erb
          editor_highlight_erb(line, line_index)
        when :css, :scss
          editor_highlight_css(line)
        when :sql
          editor_highlight_sql(line)
        else
          editor_highlight_generic(line, language, line_index)
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
        return :erb if ERB_EXTENSIONS.include?(extension)
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

      def editor_highlight_erb(line, line_index = nil)
        segments, = editor_erb_segments(line.to_s, editor_erb_state_before_line(line_index))
        output = +""
        comment = +""
        html_in_tag = false

        segments.each do |kind, text|
          if kind == :comment
            comment << text
            next
          end

          unless comment.empty?
            output << colored(comment, :gray)
            comment.clear
          end
          case kind
          when :template
            highlighted, html_in_tag = editor_highlight_html_segment(text, in_tag: html_in_tag)
            output << highlighted
          when :ruby
            output << editor_highlight_ruby(text)
          when :delimiter
            output << colored(text, :cyan)
          end
        end
        output << colored(comment, :gray) unless comment.empty?
        output
      end

      def editor_erb_state_before_line(line_index)
        return :template unless line_index && @editor_state

        state = :template
        @editor_state.lines.first(line_index.to_i).each do |line|
          _, state = editor_erb_segments(line.to_s, state)
        end
        state
      end

      def editor_erb_segments(text, state)
        segments = []
        cursor = 0

        while cursor < text.length
          if state == :template
            opening = text.match(ERB_OPEN_PATTERN, cursor)
            if opening
              segments << [:template, text[cursor...opening.begin(0)].to_s] unless opening.begin(0) == cursor
              opening_kind = opening[0] == "<%#" ? :comment : :delimiter
              segments << [opening_kind, opening[0]]
              state = opening_kind == :comment ? :comment : :ruby
              cursor = opening.end(0)
            else
              segments << [:template, text[cursor..].to_s]
              break
            end
          else
            closing = text.match(ERB_CLOSE_PATTERN, cursor)
            if closing
              segments << [state, text[cursor...closing.begin(0)].to_s] unless closing.begin(0) == cursor
              segments << [state == :comment ? :comment : :delimiter, closing[0]]
              state = :template
              cursor = closing.end(0)
            else
              segments << [state, text[cursor..].to_s]
              break
            end
          end
        end

        [segments, state]
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
        return colored(text, :gray) if definition[:block_comment] && editor_c_style_block_comment_line?(line_index)
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
        @editor_generic_patterns ||= {}
        @editor_generic_patterns[keywords] ||= /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|\b[A-Z]\w*\b|\b(?:#{Regexp.union(keywords)})\b)/
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

        lines = @editor_state.lines
        unless @editor_block_comment_lines.equal?(lines)
          @editor_block_comment_lines = lines
          @editor_block_comment_states = []
          @editor_block_comment_in_comment = false
        end

        target = line_index.to_i
        return false if target.negative?
        return @editor_block_comment_states[target] if target < @editor_block_comment_states.length

        (@editor_block_comment_states.length..target).each do |index|
          line = lines[index].to_s
          starts_block = editor_comment_index(line, "/*")
          ends_block = @editor_block_comment_in_comment && line.include?("*/")
          @editor_block_comment_states << (@editor_block_comment_in_comment || !starts_block.nil?)

          if starts_block && !line[starts_block..].to_s.include?("*/")
            @editor_block_comment_in_comment = true
          elsif ends_block
            @editor_block_comment_in_comment = false
          end
        end

        @editor_block_comment_states[target]
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

      def editor_highlight_markdown(line, line_index = nil)
        text = line.to_s
        fence_context = editor_markdown_fence_context(line_index)
        return editor_highlight_markdown_fence(text) if fence_context == :marker
        if fence_context.is_a?(Array)
          language, nested_line_index = fence_context
          return editor_highlight_language_line(text, language, nested_line_index) if language

          return text
        end

        return editor_highlight_markdown_heading(text) if text.match?(/\A\s{0,3}[#]{1,6}\s/)
        return editor_highlight_markdown_blockquote(text) if text.match?(/\A\s*>/)
        return editor_highlight_markdown_list(text) if text.match?(/\A\s*(?:[-*+]\s+|\d+\.\s+)/)

        editor_highlight_markdown_inline(text)
      end

      def editor_markdown_fence_context(line_index)
        return nil unless line_index && @editor_state

        inside_fence = false
        language = nil
        opening_index = nil
        @editor_state.lines.first(line_index.to_i + 1).each_with_index do |line, index|
          match = line.to_s.match(/\A\s*```([^`]*)\s*\z/)
          if match
            if inside_fence
              inside_fence = false
              language = nil
              opening_index = nil
            else
              inside_fence = true
              language = editor_markdown_fence_language(match[1])
              opening_index = index
            end
            return :marker if index == line_index
          elsif inside_fence && index == line_index
            return [language, index, opening_index]
          end
        end

        nil
      end

      def editor_effective_syntax_language(line_index = nil)
        language = editor_syntax_language
        return language unless language == :markdown

        context = editor_markdown_fence_context(line_index)
        context.is_a?(Array) ? context.first || :markdown : :markdown
      end

      def editor_syntax_context_start(line_index = nil)
        return nil unless editor_syntax_language == :markdown

        context = editor_markdown_fence_context(line_index)
        context.is_a?(Array) ? context[2] : nil
      end

      def editor_markdown_fence_language(info)
        name = info.to_s.strip.split(/\s/, 2).first.to_s.downcase
        ScratchpadLanguages::ALIASES[name]
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
        highlighted, = editor_highlight_html_segment(line.to_s)
        highlighted
      end

      def editor_highlight_html_segment(text, in_tag: false)
        output = +""
        cursor = 0

        while cursor < text.length
          if in_tag
            close_index = text.index(">", cursor)
            if close_index
              output << editor_highlight_html_tag_fragment(text[cursor..close_index].to_s)
              cursor = close_index + 1
              in_tag = false
            else
              output << editor_highlight_html_tag_fragment(text[cursor..].to_s)
              break
            end
            next
          end

          comment_index = text.index("<!--", cursor)
          tag = text.match(HTML_TAG_START_PATTERN, cursor)
          next_match = [comment_index, tag&.begin(0)].compact.min
          unless next_match
            output << text[cursor..].to_s
            break
          end

          output << text[cursor...next_match].to_s if next_match > cursor
          if comment_index == next_match
            close_index = text.index("-->", comment_index + 4)
            end_index = close_index ? close_index + 3 : text.length
            output << colored(text[comment_index...end_index].to_s, :gray)
            cursor = end_index
          else
            close_index = text.index(">", tag.end(0))
            end_index = close_index ? close_index + 1 : text.length
            output << editor_highlight_html_tag_fragment(text[tag.begin(0)...end_index].to_s)
            cursor = end_index
            in_tag = close_index.nil?
          end
        end

        [output, in_tag]
      end

      def editor_highlight_html_tag_fragment(tag)
        output = +""
        cursor = 0
        head = tag.match(/\A<\/?[A-Za-z][\w:-]*/)
        if head
          output << colored(head[0], :blue)
          cursor = head.end(0)
        end

        while cursor < tag.length
          rest = tag[cursor..].to_s
          if rest.start_with?(">", "/>")
            output << colored(rest.start_with?("/>") ? "/>" : ">", :blue)
            cursor += rest.start_with?("/>") ? 2 : 1
          elsif rest.match?(/\A\s/)
            whitespace = rest[/\A\s+/]
            output << whitespace
            cursor += whitespace.length
          elsif rest.start_with?("\"", "'")
            quote = rest[0]
            close_index = rest.index(quote, 1)
            if close_index
              end_index = close_index + 1
              output << colored(rest[0...end_index], :green)
              cursor += end_index
            elsif rest.end_with?(">") && rest.length > 1
              output << colored(rest[0...-1], :green)
              output << colored(">", :blue)
              cursor += rest.length
            else
              output << colored(rest, :green)
              cursor += rest.length
            end
          elsif (attribute = rest.match(/\A([A-Za-z_:][\w:.-]*)(\s*=\s*)/))
            output << colored(attribute[1], :cyan)
            output << attribute[2]
            cursor += attribute[0].length
            value = tag[cursor..].to_s
            if value.start_with?("\"", "'")
              quote = value[0]
              close_index = value.index(quote, 1)
              end_index = close_index ? close_index + 1 : value.length
              output << colored(value[0...end_index], :green)
              cursor += end_index
            elsif (unquoted = value.match(/\A[^\s>]+/))
              output << colored(unquoted[0], :green)
              cursor += unquoted[0].length
            end
          elsif (attribute = rest.match(/\A[A-Za-z_:][\w:.-]*/))
            output << colored(attribute[0], :cyan)
            cursor += attribute[0].length
          else
            output << rest[0]
            cursor += 1
          end
        end

        output
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
