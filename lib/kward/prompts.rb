require_relative "config_files"

# Namespace for the Kward CLI agent runtime.
module Kward
  # System prompt assembly from config, workspace instructions, memory, and plugins.
  module Prompts
    module_function

    def system_message(workspace_root: Dir.pwd, include_workspace_personality: true, model: nil, reasoning_effort: nil, now: Time.now, memory_context: nil, plugin_context: nil)
      {
        role: "system",
        content: prompt_parts(workspace_root: workspace_root, include_workspace_personality: include_workspace_personality, model: model, reasoning_effort: reasoning_effort, now: now, memory_context: memory_context, plugin_context: plugin_context).compact.join("\n\n")
      }
    end

    def prompt_parts(workspace_root: Dir.pwd, include_workspace_personality: true, model: nil, reasoning_effort: nil, now: Time.now, memory_context: nil, plugin_context: nil)
      prompt_sections(workspace_root: workspace_root, include_workspace_personality: include_workspace_personality, model: model, reasoning_effort: reasoning_effort, now: now, memory_context: memory_context, plugin_context: plugin_context).map { |section| section[:content] }
    end

    def prompt_sections(workspace_root: Dir.pwd, include_workspace_personality: true, model: nil, reasoning_effort: nil, now: Time.now, memory_context: nil, plugin_context: nil)
      sections = [prompt_section("Built-in system prompt", base_prompt)]
      sections << prompt_section(config_agents_prompt_label, config_agents_prompt, source: config_agents_prompt_source)
      sections << prompt_section("Memory context", memory_context) unless memory_context.to_s.empty?
      if include_workspace_personality
        sections << prompt_section("Persona", persona_prompt(workspace_root, model: model, reasoning_effort: reasoning_effort, now: now))
        sections << prompt_section("Plugin context", plugin_context) unless plugin_context.to_s.empty?
      end
      sections << prompt_section("Configured skills", skills_prompt, source: ConfigFiles.skills.empty? ? nil : File.join(ConfigFiles.config_dir, "skills"))
      sections << prompt_section(workspace_agents_context_label(workspace_root), workspace_agents_context(workspace_root), source: ConfigFiles.workspace_agents_file?(workspace_root) ? ConfigFiles.workspace_agents_path(workspace_root) : nil)
      sections.compact
    end

    def base_prompt
      <<~PROMPT.strip
        You are Kward, a concise practical CLI coding agent. Use tools to understand and modify software projects. Inspect files before changing them, make the smallest correct change, preserve existing style, and summarize what changed. Be honest about limitations.

        For web research, use web_search to discover sources, fetch_content for important human-readable pages, and fetch_raw for machine-readable resources such as JSON, YAML, XML, RSS, OpenAPI specs, and plain text. Prefer official or primary sources and cite or mention the URLs you relied on.
      PROMPT
    end

    def config_agents_prompt
      ConfigFiles.agents_prompt
    end

    def config_agents_prompt_label
      return "Config principles" if File.exist?(ConfigFiles.config_principles_path)
      return "Config AGENTS.md alias" if File.exist?(ConfigFiles.config_agents_path)

      "Config principles"
    end

    def config_agents_prompt_source
      return ConfigFiles.config_principles_path if File.exist?(ConfigFiles.config_principles_path)
      return ConfigFiles.config_agents_path if File.exist?(ConfigFiles.config_agents_path)

      nil
    end

    def persona_prompt(workspace_root = Dir.pwd, model: nil, reasoning_effort: nil, now: Time.now)
      ConfigFiles.persona_prompt(workspace_root, model: model, reasoning_effort: reasoning_effort, now: now)
    end

    def workspace_agents_context(workspace_root = Dir.pwd)
      if ConfigFiles.enforce_workspace_agents_file?
        ConfigFiles.workspace_agents_prompt(workspace_root)
      else
        workspace_agents_hint(workspace_root)
      end
    end

    def workspace_agents_prompt(workspace_root = Dir.pwd)
      ConfigFiles.workspace_agents_prompt(workspace_root)
    end

    def workspace_agents_hint(workspace_root = Dir.pwd)
      return nil unless ConfigFiles.workspace_agents_file?(workspace_root)

      path = ConfigFiles.workspace_agents_path(workspace_root)
      <<~PROMPT.strip
        Workspace guidance is available in AGENTS.md at the workspace root: #{path}
        For tasks involving this repository, read it before analyzing or modifying project files, and follow it when it does not conflict with higher-priority instructions or the user's request.
      PROMPT
    end

    def workspace_agents_context_label(workspace_root = Dir.pwd)
      return "Workspace AGENTS.md" unless ConfigFiles.workspace_agents_file?(workspace_root)
      return "Workspace AGENTS.md" if ConfigFiles.enforce_workspace_agents_file?

      "Workspace AGENTS.md hint"
    end

    def prompt_section(label, content, source: nil)
      return nil if content.to_s.empty?

      { label: label, content: content, source: source }
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
