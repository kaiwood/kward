module Kward
  # Lightweight, line-based declarations shared by file previews and the editor fallback.
  module SourceDeclarations
    module_function

    def scan(lines)
      lines.each_with_index.filter_map do |line, index|
        declaration = source_declaration(line.strip)
        declaration&.merge(line: index + 1, indent: line[/\A\s*/].to_s.length)
      end
    end

    def source_declaration(stripped)
      kind, name = case stripped
                   when /\Aclass\s+<<\s+(\S+)/
                     ["class", "<< #{Regexp.last_match(1)}"]
                   when /\A(module|class)\s+(\S+)/
                     [Regexp.last_match(1), Regexp.last_match(2).split(/[;<]/, 2).first]
                   when /\A(?:async\s+)?def\s+([^\s(;]+)/
                     ["function", Regexp.last_match(1)]
                   when /\A(?:export\s+)?(?:async\s+)?function\s+\*?\s*([^\s(<]+)/
                     ["function", Regexp.last_match(1)]
                   when /\A(?:async\s+)?(?:get\s+|set\s+)?([A-Za-z_$][\w$]*)\s*\([^;]*\)\s*(?::\s*[^{}]+)?\s*(?:\{\}|\{|=>)?\z/
                     method = Regexp.last_match(1)
                     ["method", method] unless %w[if for while switch catch].include?(method)
                   when /\A(?:export\s+)?(class|interface|type|enum)\s+([^\s<{=]+)/
                     [Regexp.last_match(1), Regexp.last_match(2)]
                   when /\A(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=.*=>/
                     ["function", Regexp.last_match(1)]
                   when /\Afunc\s+(?:\([^)]*\)\s+)?([^\s(\[]+)/
                     ["function", Regexp.last_match(1)]
                   when /\Atype\s+(\w+)\s+(struct|interface)\b/
                     [Regexp.last_match(2), Regexp.last_match(1)]
                   when /\A(?:pub\s+)?(?:async\s+)?fn\s+([^\s(<]+)/
                     ["function", Regexp.last_match(1)]
                   when /\A(?:pub\s+)?(struct|enum|trait|impl)\b\s*([^\s<{(]+)?/
                     [Regexp.last_match(1), Regexp.last_match(2) || Regexp.last_match(1)]
                   when /\A(?:public|private|protected|internal|static|final|abstract|async|override|virtual|sealed|readonly|partial|\s)+\s*(class|interface|enum|record)\s+([^\s<{(]+)/
                     [Regexp.last_match(1), Regexp.last_match(2)]
                   when /\A(?:public|private|protected|internal|static|final|abstract|async|override|virtual|sealed|readonly|partial|\s)+\s*\S[^{;=]*\b(\w+)\s*\([^;]*\)\s*(?:\{|=>)?\z/
                     ["method", Regexp.last_match(1)]
                   end
      { kind: kind, name: name, signature: stripped } if kind
    end
  end
end
