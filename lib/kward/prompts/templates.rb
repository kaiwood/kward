module Kward
  module Prompts
    class Templates
      def initialize(config_dir:, template_class:, markdown_parser:)
        @config_dir = config_dir
        @template_class = template_class
        @markdown_parser = markdown_parser
      end

      def prompt_templates(reserved_commands: [])
        prompts_root = File.join(@config_dir, "prompts")
        return [] unless Dir.exist?(prompts_root)

        reserved = reserved_commands.map(&:to_s)
        seen = {}
        Dir.glob(File.join(prompts_root, "*.md")).sort.filter_map do |path|
          template = parse_prompt_template(path)
          next unless template

          if reserved.include?(template.command)
            warn "Warning: skipping Kward prompt command /#{template.command}: reserved command"
            next
          end
          if seen[template.command]
            warn "Warning: skipping duplicate Kward prompt command /#{template.command}: #{path}"
            next
          end

          seen[template.command] = true
          template
        end
      rescue StandardError => e
        warn "Warning: skipping Kward prompt templates in #{prompts_root}: #{e.message}"
        []
      end

      private

      def parse_prompt_template(path)
        command = File.basename(path, ".md")
        unless command.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
          warn "Warning: skipping Kward prompt template #{path}: invalid command name"
          return nil
        end

        frontmatter, body = @markdown_parser.call(path)
        @template_class.new(
          command: command,
          description: frontmatter.fetch("description", "").to_s.strip,
          argument_hint: frontmatter.fetch("argument-hint", "").to_s.strip,
          body: body,
          path: path
        )
      rescue StandardError => e
        warn "Warning: skipping Kward prompt template #{path}: #{e.message}"
        nil
      end
    end
  end
end
