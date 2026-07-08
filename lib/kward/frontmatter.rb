require "yaml"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Markdown frontmatter parsing shared by prompt templates and skills.
  module Frontmatter
    module_function

    def markdown_parts(path, lenient: false)
      content = File.read(path)
      return [{}, content] unless content.start_with?("---\n", "---\r\n")

      _opening, rest = content.split(/\A---\r?\n/, 2)
      yaml_text, body = rest.to_s.split(/\r?\n---\r?\n/, 2)
      raise "missing frontmatter closing delimiter" if body.nil?

      data = yaml_text.to_s.empty? ? {} : load_frontmatter(yaml_text, lenient: lenient)
      frontmatter = data.is_a?(Hash) ? data.transform_keys(&:to_s) : {}
      [frontmatter, body]
    end

    def load_frontmatter(yaml_text, lenient: false)
      YAML.safe_load(yaml_text, permitted_classes: [], aliases: false)
    rescue Psych::SyntaxError
      raise unless lenient

      lenient_frontmatter(yaml_text)
    end

    def lenient_frontmatter(yaml_text)
      yaml_text.each_line.each_with_object({}) do |line, result|
        match = line.chomp.match(/\A([A-Za-z0-9_-]+):\s*(.*)\z/)
        next unless match

        key = match[1]
        value = match[2].strip
        next if value.empty?

        result[key] = value.delete_prefix('"').delete_suffix('"')
      end
    end
  end
end
