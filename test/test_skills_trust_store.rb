require_relative "test_helper"
require_relative "../lib/kward/skills/trust_store"

class TestSkillsTrustStore < KwardTestCase
  def test_decisions_are_scoped_to_workspace_and_skill_digest
    Dir.mktmpdir("kward-skills") do |directory|
      config_dir = File.join(directory, "config")
      workspace = File.join(directory, "workspace")
      skill_path = File.join(workspace, ".agents", "skills", "review", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill_path))
      File.write(skill_path, "name: review\n")

      store = Kward::Skills::TrustStore.new(config_dir: config_dir)
      digest = Kward::Skills::TrustStore.digest_files([skill_path], root: workspace)

      assert_nil store.decision(workspace_root: workspace, skill_path: skill_path, digest: digest)

      store.set_decision!(workspace_root: workspace, skill_path: skill_path, digest: digest, decision: "allow")

      assert_equal "allow", store.decision(workspace_root: workspace, skill_path: skill_path, digest: digest)
      assert_nil store.decision(workspace_root: workspace, skill_path: skill_path, digest: "changed")
      assert_nil store.decision(workspace_root: File.join(directory, "other"), skill_path: skill_path, digest: digest)
    end
  end

  def test_decisions_can_be_denied_and_removed
    Dir.mktmpdir("kward-skills") do |directory|
      workspace = File.join(directory, "workspace")
      skill_path = File.join(workspace, ".kward", "skills", "testing", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill_path))
      File.write(skill_path, "name: testing\n")
      digest = Kward::Skills::TrustStore.digest_files([skill_path], root: workspace)
      store = Kward::Skills::TrustStore.new(config_dir: File.join(directory, "config"))

      store.set_decision!(workspace_root: workspace, skill_path: skill_path, digest: digest, decision: "deny")
      assert_equal "deny", store.decision(workspace_root: workspace, skill_path: skill_path, digest: digest)

      store.remove_skill!(workspace_root: workspace, skill_path: skill_path)
      assert_nil store.decision(workspace_root: workspace, skill_path: skill_path, digest: digest)
    end
  end

  def test_invalid_decisions_and_outside_workspace_skills_are_rejected
    Dir.mktmpdir("kward-skills") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      outside_skill = File.join(directory, "outside", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(outside_skill))
      File.write(outside_skill, "name: outside\n")
      store = Kward::Skills::TrustStore.new(config_dir: File.join(directory, "config"))

      assert_raises(ArgumentError) do
        store.set_decision!(workspace_root: workspace, skill_path: outside_skill, digest: "digest", decision: "allow")
      end
      assert_raises(ArgumentError) do
        store.set_decision!(workspace_root: workspace, skill_path: outside_skill, digest: "digest", decision: "maybe")
      end
      assert_raises(ArgumentError) do
        Kward::Skills::TrustStore.digest_files([outside_skill], root: workspace)
      end
    end
  end
end
