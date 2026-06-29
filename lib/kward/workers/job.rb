require "securerandom"
require "time"
require_relative "../config_files"

module Kward
  module Workers
    # Persistent queue entry for a session-backed worker.
    class Job
      STATUSES = %w[queued running suspended ready_for_review failed blocked cancelled archived].freeze

      def initialize(id: SecureRandom.hex(4), title:, session_path:, workspace_root: Dir.pwd, status: "queued", position: nil, commit_sha: nil, stash_ref: nil, error: nil, enqueued_at: Time.now.utc, started_at: nil, finished_at: nil, updated_at: nil)
        @id = id.to_s
        @title = title.to_s
        @session_path = session_path.to_s
        @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
        @status = status.to_s
        @position = position
        @commit_sha = commit_sha
        @stash_ref = stash_ref
        @error = error
        @enqueued_at = enqueued_at
        @started_at = started_at
        @finished_at = finished_at
        @updated_at = updated_at || enqueued_at
      end

      attr_reader :id, :title, :session_path, :workspace_root, :position, :commit_sha, :stash_ref, :error, :enqueued_at, :started_at, :finished_at, :updated_at

      def status
        @status
      end

      def update_status(status, commit_sha: nil, stash_ref: nil, error: nil, position: nil)
        @status = status.to_s
        @commit_sha = commit_sha unless commit_sha.nil?
        @stash_ref = stash_ref unless stash_ref.nil?
        @error = error unless error.nil?
        @position = position unless position.nil?
        now = Time.now.utc
        @updated_at = now
        @started_at ||= now if @status == "running"
        @finished_at = now if %w[ready_for_review failed blocked cancelled archived].include?(@status)
        self
      end

      def to_h
        {
          "id" => id,
          "title" => title,
          "session_path" => session_path,
          "workspace_root" => workspace_root,
          "status" => status,
          "position" => position,
          "commit_sha" => commit_sha,
          "stash_ref" => stash_ref,
          "error" => error,
          "enqueued_at" => timestamp(enqueued_at),
          "started_at" => timestamp(started_at),
          "finished_at" => timestamp(finished_at),
          "updated_at" => timestamp(updated_at)
        }
      end

      def self.from_h(record)
        new(
          id: record.fetch("id"),
          title: record.fetch("title"),
          session_path: record.fetch("session_path"),
          workspace_root: record["workspace_root"] || Dir.pwd,
          status: record["status"] || "queued",
          position: record["position"],
          commit_sha: record["commit_sha"],
          stash_ref: record["stash_ref"],
          error: record["error"],
          enqueued_at: parse_time(record["enqueued_at"]) || Time.now.utc,
          started_at: parse_time(record["started_at"]),
          finished_at: parse_time(record["finished_at"]),
          updated_at: parse_time(record["updated_at"])
        )
      end

      def self.parse_time(value)
        return nil if value.to_s.empty?

        Time.parse(value.to_s).utc
      rescue ArgumentError
        nil
      end

      private_class_method :parse_time

      private

      def timestamp(value)
        value&.utc&.iso8601(3)
      end
    end
  end
end
