require_relative "config_files"

module Kward
  module Prompts
    module_function

    def system_message(workspace_root: Dir.pwd, include_workspace_personality: true)
      {
        role: "system",
        content: prompt_parts(workspace_root: workspace_root, include_workspace_personality: include_workspace_personality).compact.join("\n\n")
      }
    end

    def prompt_parts(workspace_root: Dir.pwd, include_workspace_personality: true)
      parts = [base_prompt, config_agents_prompt]
      parts << workspace_system_prompt(workspace_root) if include_workspace_personality
      parts + [workspace_agents_prompt(workspace_root), skills_prompt]
    end

    def base_prompt
      <<~PROMPT.strip
        You are Kward, a concise practical CLI coding agent. You are allowed to use the tools. Help users understand and modify software projects. Inspect files before changing them, make the smallest correct change, preserve existing style, and summarize what changed. Be honest about limitations.
      PROMPT
    end

    def config_agents_prompt
      ConfigFiles.agents_prompt
    end

    def workspace_system_prompt(workspace_root = Dir.pwd)
      ConfigFiles.workspace_system_prompt(workspace_root)
    end

    def workspace_agents_prompt(workspace_root = Dir.pwd)
      ConfigFiles.workspace_agents_prompt(workspace_root)
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
end
