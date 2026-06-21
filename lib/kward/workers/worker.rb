require "securerandom"
require "time"
require_relative "../config_files"
require_relative "../cancellation"

module Kward
  module Workers
    # Runtime record for one independent unit of agent work.
    class Worker
      STATUSES = %w[idle queued running ready failed cancelled archived].freeze

      def initialize(id: SecureRandom.hex(4), title:, role:, workspace_root: Dir.pwd, status: "idle", prompt: nil, conversation: nil, session: nil, cancellation: Cancellation.new, created_at: Time.now.utc)
        @id = id
        @title = title.to_s
        @role = role.to_s
        @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
        @status = status.to_s
        @prompt = prompt.to_s
        @conversation = conversation
        @session = session
        @cancellation = cancellation
        @created_at = created_at
        @updated_at = created_at
        @started_at = nil
        @finished_at = nil
        @report = nil
        @error = nil
        @thread = nil
        @event_history = []
        @event_queue = Queue.new
      end

      attr_reader :id, :title, :role, :workspace_root, :prompt, :conversation, :session, :cancellation, :created_at, :updated_at, :started_at, :finished_at, :report, :error, :thread, :event_history, :event_queue
      attr_writer :conversation, :session, :thread

      def status
        @status
      end

      def update_status(status, error: nil, report: nil)
        @status = status.to_s
        @error = error unless error.nil?
        @report = report unless report.nil?
        now = Time.now.utc
        @updated_at = now
        @started_at ||= now if @status == "running"
        @finished_at = now if %w[ready failed cancelled archived].include?(@status)
        self
      end

      def record_event(event)
        @event_history << event
        @event_queue << event
      end

      def to_h
        {
          "id" => id,
          "title" => title,
          "role" => role,
          "status" => status,
          "prompt" => prompt,
          "workspace_root" => workspace_root,
          "session_id" => session&.id,
          "session_path" => session&.path,
          "created_at" => timestamp(created_at),
          "updated_at" => timestamp(updated_at),
          "started_at" => timestamp(started_at),
          "finished_at" => timestamp(finished_at),
          "report" => report,
          "error" => error
        }
      end

      private

      def timestamp(value)
        value&.utc&.iso8601(3)
      end
    end
  end
end
