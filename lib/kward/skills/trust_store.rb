require "digest"
require "json"
require "pathname"
require_relative "../path_guard"
require_relative "../private_file"

# Namespace for Agent Skills discovery and trust management.
module Kward
  module Skills
    # Persists workspace-scoped decisions for project skill snapshots.
    class TrustStore
      DECISIONS = %w[allow deny].freeze

      attr_reader :path

      def initialize(config_dir:)
        @path = File.join(File.expand_path(config_dir), "trusted_project_skills.json")
      end

      def decision(workspace_root:, skill_path:, digest:)
        record = skill_record(workspace_root: workspace_root, skill_path: skill_path)
        return unless record
        return unless record["digest"] == digest.to_s

        decision = record["decision"]
        decision if DECISIONS.include?(decision)
      end

      def set_decision!(workspace_root:, skill_path:, digest:, decision:)
        decision = decision.to_s
        raise ArgumentError, "invalid project skill trust decision: #{decision}" unless DECISIONS.include?(decision)

        config = read_config
        workspace = workspace_key(workspace_root)
        skill = skill_key(workspace_root, skill_path)
        config["workspaces"] ||= {}
        config["workspaces"][workspace] ||= { "skills" => {} }
        config["workspaces"][workspace]["skills"] ||= {}
        config["workspaces"][workspace]["skills"][skill] = {
          "digest" => digest.to_s,
          "decision" => decision
        }
        PrivateFile.write_json(path, config)
      end

      def remove_workspace!(workspace_root:)
        config = read_config
        config.fetch("workspaces", {}).delete(workspace_key(workspace_root))
        PrivateFile.write_json(path, config)
      end

      def remove_skill!(workspace_root:, skill_path:)
        config = read_config
        workspace = config.fetch("workspaces", {})[workspace_key(workspace_root)]
        workspace&.fetch("skills", {})&.delete(skill_key(workspace_root, skill_path))
        PrivateFile.write_json(path, config)
      end

      def self.digest_files(paths, root: nil)
        root = File.realpath(root) if root
        digest = Digest::SHA256.new
        paths.map { |path| File.realpath(path) }.sort.each do |path|
          raise ArgumentError, "file is outside digest root" if root && !PathGuard.inside?(path, root)

          relative_path = root ? Pathname.new(path).relative_path_from(Pathname.new(root)).to_s : path
          digest.update(relative_path)
          digest.update("\0")
          digest.update(File.binread(path))
          digest.update("\0")
        end
        digest.hexdigest
      end

      private

      def skill_record(workspace_root:, skill_path:)
        workspace = read_config.fetch("workspaces", {})[workspace_key(workspace_root)]
        workspace&.fetch("skills", {})&.[](skill_key(workspace_root, skill_path))
      end

      def read_config
        return {} unless File.file?(path)

        config = JSON.parse(File.read(path))
        config.is_a?(Hash) ? config : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def workspace_key(workspace_root)
        File.realpath(workspace_root)
      rescue SystemCallError
        File.expand_path(workspace_root)
      end

      def skill_key(workspace_root, skill_path)
        workspace = workspace_key(workspace_root)
        skill = File.realpath(skill_path)
        raise ArgumentError, "project skill is outside workspace" unless PathGuard.inside?(skill, workspace)

        Pathname.new(skill).relative_path_from(Pathname.new(workspace)).to_s
      rescue SystemCallError
        raise ArgumentError, "project skill path does not exist"
      end
    end
  end
end
