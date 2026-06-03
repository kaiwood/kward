require_relative "config_files"

module Kward
  module Prompts
    module_function

    def system_message
      {
        role: "system",
        content: prompt_parts.compact.join("\n\n")
      }
    end

    def prompt_parts
      [base_prompt, bundled_agents_prompt, config_agents_prompt, skills_prompt]
    end

    def base_prompt
      <<~PROMPT.strip
        You are Kward, a concise practical CLI coding agent. You are allowed to use the tools. Help users understand and modify software projects. Inspect files before changing them, make the smallest correct change, preserve existing style, and summarize what changed. Be honest about limitations.
      PROMPT
    end

    def bundled_agents_prompt
      File.read(File.expand_path("../../AGENTS.md", __dir__))
    end

    def config_agents_prompt
      ConfigFiles.agents_prompt
    end

    def skills_prompt
      skills = ConfigFiles.skills
      return nil if skills.empty?

      lines = [
        "Configured skills are available in the Kward config directory.",
        "When a task matches a skill, use read_skill to load its instructions before proceeding.",
        "Available skills:"
      ]
      skills.each do |skill|
        description = skill.description.empty? ? "No description provided." : skill.description
        lines << "- #{skill.name}: #{description}"
      end
      lines.join("\n")
    end
  end

  SYSTEM_MESSAGE = Prompts.system_message
end
