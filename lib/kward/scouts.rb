require "json"
require "securerandom"
require "time"
require_relative "config_files"
require_relative "workers"

module Kward
  # Persistent read-only background scouting jobs for preparing future work.
  module Scouts
    STATUSES = %w[queued running ready failed cancelled dismissed started].freeze
    ACTIVE_STATUSES = %w[queued running ready failed cancelled].freeze

    module_function

    def default_path
      File.join(ConfigFiles.config_dir, "scouts.json")
    end

    def now
      Time.now.utc.iso8601(3)
    end

    def title_for(prompt)
      text = prompt.to_s.strip.gsub(/\s+/, " ")
      text.empty? ? "Untitled scout" : text[0, 80]
    end

    # JSON-backed store for scout jobs.
    class Store
      def initialize(path: Scouts.default_path)
        @path = path
        @mutex = Mutex.new
      end

      attr_reader :path

      def create(prompt:, workspace_root: Dir.pwd)
        timestamp = Scouts.now
        job = {
          "id" => SecureRandom.hex(4),
          "title" => Scouts.title_for(prompt),
          "prompt" => prompt.to_s,
          "workspace_root" => ConfigFiles.canonical_workspace_root(workspace_root),
          "status" => "queued",
          "created_at" => timestamp,
          "updated_at" => timestamp,
          "started_at" => nil,
          "finished_at" => nil,
          "report" => nil,
          "error" => nil,
          "session_id" => nil,
          "session_path" => nil
        }
        update_jobs { |jobs| jobs << job }
        job
      end

      def list(include_dismissed: false)
        jobs = read_jobs
        jobs = jobs.reject { |job| job["status"] == "dismissed" } unless include_dismissed
        jobs.sort_by { |job| job["created_at"].to_s }
      end

      def find(id)
        read_jobs.find { |job| job["id"] == id.to_s }
      end

      def update(id, values)
        replacement = nil
        update_jobs do |jobs|
          index = jobs.index { |job| job["id"] == id.to_s }
          raise ArgumentError, "Unknown scout: #{id}" unless index

          replacement = jobs[index].merge(stringify_keys(values)).merge("updated_at" => Scouts.now)
          jobs[index] = replacement
        end
        replacement
      end

      def dismiss(id)
        update(id, "status" => "dismissed")
      end

      def mark_started(id)
        update(id, "status" => "started")
      end

      private

      def read_jobs
        @mutex.synchronize { read_jobs_unlocked }
      end

      def read_jobs_unlocked
        return [] unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        data.is_a?(Array) ? data : []
      rescue JSON::ParserError
        raise "Invalid scout store JSON: #{@path}"
      end

      def update_jobs
        @mutex.synchronize do
          jobs = read_jobs_unlocked
          yield jobs
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, JSON.pretty_generate(jobs) + "\n")
        end
      end

      def stringify_keys(values)
        values.to_h.transform_keys(&:to_s)
      end
    end

    # Compatibility wrapper that runs scout jobs through the worker manager.
    class Runner
      READ_ONLY_TOOLS = Workers::ToolPolicy::READ_ONLY_TOOLS
      DEFAULT_TIMEOUT_SECONDS = Workers::Manager::DEFAULT_TIMEOUT_SECONDS

      def initialize(store:, client: nil, prompt: nil, workspace_root: Dir.pwd, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, client_factory: nil, session_store: nil, provider: nil, model: nil, reasoning_effort: nil, write_lock: nil)
        @store = store
        @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
        @manager = Workers::Manager.new(
          client_factory: client_factory || -> { client || Client.new },
          prompt: prompt,
          workspace_root: @workspace_root,
          timeout_seconds: timeout_seconds,
          on_status_change: method(:sync_worker),
          session_store: session_store,
          provider: provider,
          model: model,
          reasoning_effort: reasoning_effort,
          write_lock: write_lock
        )
      end

      def start(prompt)
        job = @store.create(prompt: prompt, workspace_root: @workspace_root)
        @manager.start(role: "scout", prompt: prompt, title: job.fetch("title"), id: job.fetch("id"))
        job
      end

      def cancel(id)
        @manager.cancel(id)
        @store.update(id, "status" => "cancelled", "finished_at" => Scouts.now)
      rescue ArgumentError
        @store.update(id, "status" => "cancelled", "finished_at" => Scouts.now)
      end

      def worker(id)
        @manager.find(id)
      end

      private

      def sync_worker(worker)
        values = {
          "status" => worker.status,
          "started_at" => worker.started_at && worker.started_at.utc.iso8601(3),
          "finished_at" => worker.finished_at && worker.finished_at.utc.iso8601(3),
          "report" => worker.report,
          "error" => worker.error,
          "session_id" => worker.session&.id,
          "session_path" => worker.session&.path
        }.compact
        @store.update(worker.id, values)
      rescue StandardError
        nil
      end
    end
  end
end
