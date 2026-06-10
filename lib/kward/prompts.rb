require_relative "config_files"
require_relative "news_cache"

module Kward
  module Prompts
    module_function

    def system_message(workspace_root: Dir.pwd, include_workspace_personality: true, model: nil, reasoning_effort: nil, now: Time.now, memory_context: nil)
      {
        role: "system",
        content: prompt_parts(workspace_root: workspace_root, include_workspace_personality: include_workspace_personality, model: model, reasoning_effort: reasoning_effort, now: now, memory_context: memory_context).compact.join("\n\n")
      }
    end

    def prompt_parts(workspace_root: Dir.pwd, include_workspace_personality: true, model: nil, reasoning_effort: nil, now: Time.now, memory_context: nil)
      parts = [base_prompt, config_agents_prompt]
      parts << memory_context unless memory_context.to_s.empty?
      parts << persona_prompt(workspace_root, model: model, reasoning_effort: reasoning_effort, now: now) if include_workspace_personality
      parts << news_prompt if include_workspace_personality
      parts << skills_prompt
      parts << workspace_agents_prompt(workspace_root)
      parts
    end

    def base_prompt
      <<~PROMPT.strip
        You are Kward, a concise practical CLI coding agent. You are allowed to use the tools. Help users understand and modify software projects. Inspect files before changing them, make the smallest correct change, preserve existing style, and summarize what changed. Be honest about limitations.
      PROMPT
    end

    def config_agents_prompt
      ConfigFiles.agents_prompt
    end

    def persona_prompt(workspace_root = Dir.pwd, model: nil, reasoning_effort: nil, now: Time.now)
      ConfigFiles.persona_prompt(workspace_root, model: model, reasoning_effort: reasoning_effort, now: now)
    end

    def workspace_agents_prompt(workspace_root = Dir.pwd)
      ConfigFiles.workspace_agents_prompt(workspace_root)
    end

    def news_prompt
      NewsCache.new.prompt_context
    rescue StandardError => e
      warn "Warning: skipping Kward news cache: #{e.message}"
      nil
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
