require_relative "test_helper"

class TestPrompts < KwardTestCase
  def test_composer_busy_help_defaults_on_and_can_be_disabled
    assert_equal true, Kward::ConfigFiles.composer_busy_help?({})
    assert_equal true, Kward::ConfigFiles.composer_busy_help?({ "composer" => {} })
    assert_equal false, Kward::ConfigFiles.composer_busy_help?({ "composer" => { "busy_help" => false } })
  end

  def test_base_prompt_includes_web_research_guidance
    content = Kward::Prompts.base_prompt

    assert_includes content, "use web_search to discover sources"
    assert_includes content, "fetch_content for important human-readable pages"
    assert_includes content, "fetch_raw for machine-readable resources"
  end

  def test_base_prompt_includes_context_budget_guidance
    content = Kward::Prompts.base_prompt

    assert_includes content, "Prefer context_for_task"
    assert_includes content, "read_file mode=\"outline\"/\"preview\""
    assert_includes content, "use mode=\"full\" only when focused context is insufficient"
  end

  def test_config_principles_prompt_appends_from_config_dir
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        File.write(File.join(dir, "PRINCIPLES.md"), "Config prompt instructions.\n")

        with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          refute_includes content, "# PRINCIPLES.md"
          assert_includes content, "Config prompt instructions."
        end
      end
    end
  end

  def test_config_agents_prompt_alias_appends_from_config_dir
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        File.write(File.join(dir, "AGENTS.md"), "Alias prompt instructions.\n")

        with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          assert_includes content, "Alias prompt instructions."
        end
      end
    end
  end

  def test_config_principles_prompt_takes_precedence_over_agents_alias
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        File.write(File.join(dir, "PRINCIPLES.md"), "Preferred prompt instructions.\n")
        File.write(File.join(dir, "AGENTS.md"), "Alias prompt instructions.\n")

        with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          assert_includes content, "Preferred prompt instructions."
          refute_includes content, "Alias prompt instructions."
        end
      end
    end
  end

  def test_oversized_config_principles_prompt_warns_and_skips
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      File.write(File.join(dir, "PRINCIPLES.md"), "x" * (Kward::ConfigFiles::MAX_PROMPT_FILE_BYTES + 1))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        _stdout, stderr = capture_io do
          content = Kward::Conversation.new.system_message[:content]

          refute_includes content, "xxx"
        end

        assert_includes stderr, "Warning: skipping Kward principles file"
        assert_includes stderr, "file too large"
      end
    end
  end

  def test_plugin_prompt_context_is_injected_after_personas
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "personas" => { "default" => "Default persona." }
        }))
        registry = Kward::PluginRegistry.new
        registry.evaluate do |plugin|
          plugin.prompt_context { |_ctx| "Plugin context." }
        end

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace, plugin_registry: registry).system_message[:content]

          assert_order content, "Default persona.", "Plugin context."
        end
      end
    end
  end

  def test_persona_prompt_and_agents_prompt_order
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(config_dir, "PRINCIPLES.md"), "Config instructions.\n")
        skill_dir = File.join(config_dir, "skills", "planner")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n\nSkill body.\n")
        File.write(File.join(workspace, "AGENTS.md"), "Workspace instructions.\n")
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "personas" => {
            "default" => "Default persona.",
            "workspaces" => {
              workspace => "Workspace persona."
            }
          }
        }))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          assert_order content,
                       "You are Kward",
                       "Config instructions.",
                       "Workspace persona.",
                       "Available skills:",
                       "Workspace guidance is available"
          refute_includes content, "Default persona."
          assert_includes content, File.join(workspace, "AGENTS.md")
          refute_includes content, "Workspace instructions."
        end
      end
    end
  end

  def test_workspace_agents_prompt_is_injected_when_enforced
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(workspace, "AGENTS.md"), "Workspace instructions.\n")
        File.write(File.join(config_dir, "config.json"), JSON.dump("enforce_workspace_agents_file" => true))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          assert_includes content, "Workspace instructions."
          refute_includes content, "Workspace guidance is available"
        end
      end
    end
  end

  def test_oversized_workspace_agents_prompt_warns_and_skips_when_enforced
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(config_dir, "config.json"), JSON.dump("enforce_workspace_agents_file" => true))
        File.write(File.join(workspace, "AGENTS.md"), "x" * (Kward::ConfigFiles::MAX_PROMPT_FILE_BYTES + 1))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          _stdout, stderr = capture_io do
            content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

            refute_includes content, "xxx"
          end

          assert_includes stderr, "Warning: skipping workspace AGENTS.md"
          assert_includes stderr, "file too large"
        end
      end
    end
  end

  def test_different_workspaces_use_different_personas
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |first_workspace|
        Dir.mktmpdir do |second_workspace|
          File.write(File.join(config_dir, "config.json"), JSON.dump({
            "personas" => {
              "workspaces" => {
                first_workspace => "First persona.",
                second_workspace => "Second persona."
              }
            }
          }))

          with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
            first_content = Kward::Conversation.new(workspace_root: first_workspace).system_message[:content]
            second_content = Kward::Conversation.new(workspace_root: second_workspace).system_message[:content]

            assert_includes first_content, "First persona."
            refute_includes first_content, "Second persona."
            assert_includes second_content, "Second persona."
            refute_includes second_content, "First persona."
          end
        end
      end
    end
  end

  def test_crew_array_uses_instruction_field
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "personas" => {
            "crew" => [
              {
                "key" => "kward",
                "label" => "Kward",
                "instruction" => "Default persona."
              },
              {
                "key" => "spark",
                "label" => "Spark",
                "instruction" => "Workspace persona."
              },
              {
                "key" => "gpt-alt",
                "label" => "Input",
                "instruction" => "Model persona."
              }
            ],
            "default" => "kward",
            "workspaces" => {
              workspace => "spark"
            },
            "models" => {
              "gpt-test" => "gpt-alt"
            },
            "persona_modifiers" => {
              "reasoning" => {
                "low" => "Low reasoning persona."
              }
            }
          }
        }))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          content = Kward::Conversation.new(
            workspace_root: workspace,
            model: "gpt-test",
            reasoning_effort: "low"
          ).system_message[:content]

          assert_includes content, "Model persona."
          assert_includes content, "Low reasoning persona."
          refute_includes content, "Default persona."
          refute_includes content, "Workspace persona."
          refute_includes content, "kward"
          refute_includes content, "spark"
          refute_includes content, "gpt-alt"
        end
      end
    end
  end

  def test_characters_alias_resolves_persona_text_and_label
    config = {
      "personas" => {
        "characters" => {
          "kward" => {
            "label" => "Kward",
            "instruction" => "Default persona."
          }
        },
        "default" => "kward"
      }
    }

    assert_equal "Default persona.", Kward::ConfigFiles.persona_prompt(Dir.pwd, config: config)
    assert_equal "Kward", Kward::ConfigFiles.active_persona_label(workspace_root: Dir.pwd, config: config)
  end

  def test_active_persona_label_falls_back_when_no_label_is_found
    config = {
      "personas" => {
        "crew" => {
          "kward" => { "instruction" => "Default persona." }
        },
        "default" => "kward"
      }
    }

    assert_nil Kward::ConfigFiles.active_persona_label(workspace_root: Dir.pwd, config: config)
    assert_nil Kward::ConfigFiles.active_persona_label(workspace_root: Dir.pwd, config: {})
  end

  def test_missing_personas_falls_back_without_configuration
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(config_dir, "config.json"), JSON.dump({}))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          assert_includes content, "You are Kward"
          refute_includes content, "personality"
          refute_includes content, "persona"
        end
      end
    end
  end

  def test_workspace_agents_and_persona_coexist
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(workspace, "AGENTS.md"), "Run focused tests.\n")
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "personas" => {
            "workspaces" => {
              workspace => "Speak tersely."
            }
          }
        }))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          assert_includes content, "Speak tersely."
          assert_includes content, "Workspace guidance is available"
          refute_includes content, "Run focused tests."
        end
      end
    end
  end

  def test_model_reasoning_time_weekday_and_suffix_personas_append_in_order
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "personas" => {
            "crew" => {
              "kward" => {
                "label" => "Kward",
                "instruction" => "Default persona."
              },
              "spark" => {
                "label" => "Spark",
                "instruction" => "Workspace persona."
              },
              "gpt-alt" => {
                "label" => "Input",
                "instruction" => "Model persona."
              }
            },
            "default" => "kward",
            "workspaces" => {
              workspace => "spark"
            },
            "models" => {
              "gpt-test" => "gpt-alt"
            },
            "persona_modifiers" => {
              "reasoning" => {
                "low" => "Low reasoning persona."
              },
              "time_of_day" => {
                "morning" => "Morning persona."
              },
              "weekday" => {
                "sunday" => "Sunday persona."
              },
              "unknown" => {
                "ignored" => "Ignored persona."
              },
              "suffix" => "Act like it."
            }
          }
        }))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          content = Kward::Prompts.system_message(
            workspace_root: workspace,
            model: "gpt-test",
            reasoning_effort: "low",
            now: Time.new(2024, 6, 2, 5, 30, 0)
          )[:content]

          assert_order content,
                       "Model persona.",
                       "Low reasoning persona.",
                       "Morning persona.",
                       "Sunday persona.",
                       "Act like it."
          refute_includes content, "Default persona."
          refute_includes content, "Workspace persona."
          refute_includes content, "Ignored persona."
          refute_includes content, "kward"
          refute_includes content, "spark"
          refute_includes content, "gpt-alt"
        end
      end
    end
  end

  def test_time_of_day_buckets
    config = {
      "personas" => {
        "persona_modifiers" => {
          "time_of_day" => {
            "morning" => "Morning.",
            "before_lunch" => "Hungry.",
            "late_evening" => "Tired."
          }
        }
      }
    }

    assert_includes Kward::ConfigFiles.persona_prompt(Dir.pwd, now: Time.new(2024, 1, 1, 5), config: config), "Morning."
    assert_includes Kward::ConfigFiles.persona_prompt(Dir.pwd, now: Time.new(2024, 1, 1, 11), config: config), "Hungry."
    assert_includes Kward::ConfigFiles.persona_prompt(Dir.pwd, now: Time.new(2024, 1, 1, 21), config: config), "Tired."
    assert_includes Kward::ConfigFiles.persona_prompt(Dir.pwd, now: Time.new(2024, 1, 1, 4), config: config), "Tired."
    assert_nil Kward::ConfigFiles.persona_prompt(Dir.pwd, now: Time.new(2024, 1, 1, 12), config: config)

    entries = Kward::ConfigFiles.persona_entries(
      workspace_root: Dir.pwd,
      now: Time.new(2024, 1, 1, 5),
      config: config,
      include_reasoning: false
    )
    assert_equal [
      { layer: "time_of_day", name: "morning", prompt: "Morning." }
    ], entries
  end

  def test_config_skills_are_listed_without_body
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n\nSecret full body.\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        content = Kward::Conversation.new.system_message[:content]

        assert_includes content, "Available skills:"
        assert_includes content, "- planner: Helps plan work."
        assert_includes content, "Agent Skills are available."
        assert_includes content, "use read_skill"
        assert_includes content, "relative path"
        refute_includes content, "Secret full body."
      end
    end
  end

  def test_project_skills_use_conversation_workspace_root_without_chdir
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      other_workspace = File.join(dir, "other")
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(other_workspace)
      File.write(File.join(config_dir, "config.json"), JSON.dump({ "skills" => { "trust_project" => true } }))

      skill_dir = File.join(workspace, ".agents", "skills", "project-agent")
      other_skill_dir = File.join(other_workspace, ".agents", "skills", "wrong-agent")
      FileUtils.mkdir_p(skill_dir)
      FileUtils.mkdir_p(other_skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: project-agent\ndescription: Project workspace skill.\n---\n")
      File.write(File.join(other_skill_dir, "SKILL.md"), "---\nname: wrong-agent\ndescription: Wrong workspace skill.\n---\n")

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        Dir.chdir(other_workspace) do
          content = Kward::Conversation.new(workspace_root: workspace).system_message[:content]

          assert_includes content, "- project-agent: Project workspace skill."
          refute_includes content, "wrong-agent"
        end
      end
    end
  end

  def test_skills_include_project_and_shared_agent_skill_locations
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(workspace)
      File.write(File.join(config_dir, "config.json"), JSON.dump({ "skills" => { "trust_project" => true } }))

      skill_locations = {
        "project-kward" => File.join(workspace, ".kward", "skills", "project-kward"),
        "project-agent" => File.join(workspace, ".agents", "skills", "project-agent"),
        "user-kward" => File.join(config_dir, "skills", "user-kward"),
        "user-agent" => File.join(KWARD_TEST_HOME, ".agents", "skills", "user-agent")
      }
      skill_locations.each do |name, path|
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: #{name} description.\n---\n")
      end

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        Dir.chdir(workspace) do
          content = Kward::Conversation.new.system_message[:content]

          assert_includes content, "- project-kward: project-kward description."
          assert_includes content, "- project-agent: project-agent description."
          assert_includes content, "- user-kward: user-kward description."
          assert_includes content, "- user-agent: user-agent description."
        end
      end
    end
  ensure
    FileUtils.rm_rf(File.join(KWARD_TEST_HOME, ".agents", "skills", "user-agent"))
  end

  def test_project_skills_are_skipped_until_trusted
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(workspace)
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))

      project_skill = File.join(workspace, ".agents", "skills", "project-agent")
      user_skill = File.join(config_dir, "skills", "user-kward")
      { "project-agent" => project_skill, "user-kward" => user_skill }.each do |name, path|
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: #{name} description.\n---\n")
      end

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        Dir.chdir(workspace) do
          _stdout, stderr = capture_io do
            content = Kward::Conversation.new.system_message[:content]

            refute_includes content, "project-agent description"
            assert_includes content, "- user-kward: user-kward description."
          end

          assert_includes stderr, "project skills are not trusted"
        end
      end
    end
  end

  def test_skills_prefer_project_kward_then_project_agent_then_user_kward_then_user_agent
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(workspace)
      File.write(File.join(config_dir, "config.json"), JSON.dump({ "skills" => { "trust_project" => true } }))

      roots = [
        File.join(KWARD_TEST_HOME, ".agents", "skills", "shared"),
        File.join(config_dir, "skills", "shared"),
        File.join(workspace, ".agents", "skills", "shared"),
        File.join(workspace, ".kward", "skills", "shared")
      ]
      roots.each_with_index do |root, index|
        FileUtils.mkdir_p(root)
        File.write(File.join(root, "SKILL.md"), "---\nname: shared\ndescription: precedence #{index}.\n---\n\nbody #{index}\n")
      end

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        Dir.chdir(workspace) do
          _stdout, stderr = capture_io do
            content = Kward::Conversation.new.system_message[:content]

            assert_includes content, "- shared: precedence 3."
            refute_includes content, "precedence 2"
            refute_includes content, "precedence 1"
            refute_includes content, "precedence 0"
          end

          assert_includes stderr, "Warning: skipping duplicate Kward skill \"shared\""
        end
      end
    end
  ensure
    FileUtils.rm_rf(File.join(KWARD_TEST_HOME, ".agents", "skills", "shared"))
  end

  def test_skill_parser_keeps_optional_metadata_fields
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~SKILL)
        ---
        name: planner
        description: Helps plan work.
        license: MIT
        compatibility: Requires git.
        metadata:
          author: example
        allowed-tools: Bash(git:*) Read
        ---
      SKILL

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        skill = Kward::ConfigFiles.skills.first

        assert_equal "planner", skill.name
        assert_equal "MIT", skill.license
        assert_equal "Requires git.", skill.compatibility
        assert_equal({ "author" => "example" }, skill.metadata)
        assert_equal "Bash(git:*) Read", skill.allowed_tools
      end
    end
  end

  def test_skill_parser_accepts_common_unquoted_colon_description
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Use this skill when: planning work.\n---\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        skill = Kward::ConfigFiles.skills.first

        assert_equal "planner", skill.name
        assert_equal "Use this skill when: planning work.", skill.description
      end
    end
  end

  def test_skills_skip_missing_required_metadata
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      missing_name = File.join(dir, "skills", "missing-name")
      missing_description = File.join(dir, "skills", "missing-description")
      [missing_name, missing_description].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(missing_name, "SKILL.md"), "---\ndescription: Missing name.\n---\n")
      File.write(File.join(missing_description, "SKILL.md"), "---\nname: missing-description\n---\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        _stdout, stderr = capture_io do
          assert_empty Kward::ConfigFiles.skills
        end

        assert_includes stderr, "missing name"
        assert_includes stderr, "missing description"
      end
    end
  end

  def test_invalid_config_prompt_and_skill_warn_and_skip
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      Dir.mkdir(File.join(dir, "PRINCIPLES.md"))
      invalid_skill_path = File.join(dir, "skills", "bad", "SKILL.md")
      FileUtils.mkdir_p(invalid_skill_path)

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        _stdout, stderr = capture_io do
          content = Kward::Conversation.new.system_message[:content]

          refute_includes content, "Available skills:"
        end

        assert_includes stderr, "Warning: skipping Kward principles file"
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
