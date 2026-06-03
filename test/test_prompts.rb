require_relative "test_helper"

class TestPrompts < KwardTestCase
  def test_config_agents_prompt_appends_from_config_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      File.write(File.join(dir, "AGENTS.md"), "Config prompt instructions.\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        content = Kward::Conversation.new.messages.first[:content]

        refute_includes content, "# AGENTS.md"
        assert_includes content, "Config prompt instructions."
      end
    end
  end

  def test_config_skills_are_listed_without_body
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n\nSecret full body.\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        content = Kward::Conversation.new.messages.first[:content]

        assert_includes content, "Available skills:"
        assert_includes content, "- planner: Helps plan work."
        assert_includes content, "use read_skill"
        refute_includes content, "Secret full body."
      end
    end
  end

  def test_invalid_config_prompt_and_skill_warn_and_skip
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      Dir.mkdir(File.join(dir, "AGENTS.md"))
      invalid_skill_path = File.join(dir, "skills", "bad", "SKILL.md")
      FileUtils.mkdir_p(invalid_skill_path)

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        _stdout, stderr = capture_io do
          content = Kward::Conversation.new.messages.first[:content]

          refute_includes content, "Available skills:"
        end

        assert_includes stderr, "Warning: skipping Kward prompt file"
        assert_includes stderr, "Warning: skipping Kward skill"
      end
    end
  end

  def test_config_prompt_templates_parse_and_expand_arguments
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "plan.md"), "---\ndescription: Plan work.\nargument-hint: <task>\n---\nPlan this:\n$ARGUMENTS\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        template = Kward::ConfigFiles.prompt_templates.first

        assert_equal "plan", template.command
        assert_equal "Plan work.", template.description
        assert_equal "<task>", template.argument_hint
        assert_equal "Plan this:\nfix bug\n", template.expand("fix bug")
      end
    end
  end

  def test_prompt_templates_skip_reserved_commands_with_warning
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "exit.md"), "Do not override.\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        _stdout, stderr = capture_io do
          assert_empty Kward::ConfigFiles.prompt_templates(reserved_commands: ["exit"])
        end

        assert_includes stderr, "reserved command"
      end
    end
  end

  def test_prompt_templates_warn_and_skip_invalid_frontmatter
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "bad.md"), "---\ndescription: [\n---\nBad\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        _stdout, stderr = capture_io do
          assert_empty Kward::ConfigFiles.prompt_templates
        end

        assert_includes stderr, "Warning: skipping Kward prompt template"
      end
    end
  end

end
