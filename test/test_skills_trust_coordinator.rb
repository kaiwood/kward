require_relative "test_helper"
require_relative "../lib/kward/skills/registry"
require_relative "../lib/kward/skills/trust_coordinator"
require_relative "../lib/kward/skills/trust_store"

class TestSkillsTrustCoordinator < KwardTestCase
  def test_pending_and_allowed_paths_follow_snapshot_decisions
    Dir.mktmpdir("kward-skills") do |directory|
      workspace = File.join(directory, "workspace")
      first = create_skill(workspace, "first")
      second = create_skill(workspace, "second")
      candidates = candidates_for(workspace, first, second)
      store = Kward::Skills::TrustStore.new(config_dir: File.join(directory, "config"))
      coordinator = Kward::Skills::TrustCoordinator.new(workspace_root: workspace, trust_store: store)

      assert_equal candidates, coordinator.pending(candidates)
      assert_empty coordinator.allowed_paths(candidates)

      coordinator.record!([candidates.first], "allow")
      coordinator.record!([candidates.last], "deny")

      assert_empty coordinator.pending(candidates)
      assert_equal [first], coordinator.allowed_paths(candidates)
    end
  end

  def test_changed_skill_snapshot_requires_a_new_decision
    Dir.mktmpdir("kward-skills") do |directory|
      workspace = File.join(directory, "workspace")
      path = create_skill(workspace, "review")
      candidate = candidates_for(workspace, path).first
      store = Kward::Skills::TrustStore.new(config_dir: File.join(directory, "config"))
      coordinator = Kward::Skills::TrustCoordinator.new(workspace_root: workspace, trust_store: store)

      coordinator.record!([candidate], "allow")
      File.write(path, "---\nname: review\ndescription: changed\n---\n")
      changed = candidates_for(workspace, path)

      assert_equal [changed.first], coordinator.pending(changed)
      assert_empty coordinator.allowed_paths(changed)
    end
  end

  private

  def create_skill(workspace, name)
    path = File.join(workspace, ".agents", "skills", name, "SKILL.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "---\nname: #{name}\ndescription: #{name}\n---\n")
    path
  end

  def candidates_for(workspace, *paths)
    paths.map do |path|
      Kward::Skills::Registry::SkillCandidate.new(
        path: path,
        root: File.dirname(path),
        label: "project Agent Skills",
        scope: :project,
        digest: Kward::Skills::TrustStore.digest_files([path], root: workspace)
      )
    end
  end
end
