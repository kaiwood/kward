require "fileutils"
require "json"
require_relative "../config_files"
require_relative "job"

module Kward
  module Workers
    # JSON-backed queue store for session-backed worker jobs.
    class QueueStore
      def initialize(path: File.join(ConfigFiles.config_dir, "worker_queue.json"))
        @path = path
        @mutex = Mutex.new
      end

      attr_reader :path

      def enqueue(title:, session_path:, workspace_root:, id: nil)
        job = Job.new(
          id: id || SecureRandom.hex(4),
          title: title,
          session_path: session_path,
          workspace_root: workspace_root,
          position: next_position
        )
        upsert(job)
        job
      end

      def upsert(job)
        record = job.respond_to?(:to_h) ? job.to_h : job.to_h
        update_records do |records|
          index = records.index { |item| item["id"] == record["id"] }
          index ? records[index] = record : records << record
          normalize_positions(records)
        end
        record
      end

      def list(include_archived: false)
        records = read_records
        records = records.reject { |record| record["status"] == "archived" } unless include_archived
        sorted(records)
      end

      def find(id)
        read_records.find { |record| record["id"] == id.to_s }
      end

      def update_status(id, status, **values)
        record = nil
        update_records do |records|
          index = records.index { |item| item["id"] == id.to_s }
          raise ArgumentError, "Unknown worker job: #{id}" unless index

          job = Job.from_h(records[index])
          job.update_status(status, **values)
          record = job.to_h
          records[index] = record
          normalize_positions(records)
        end
        record
      end

      def archive(id)
        update_status(id, "archived")
      end

      def next_queued
        list.find { |record| record["status"] == "queued" }
      end

      private

      def next_position
        last = list(include_archived: true).map { |record| record["position"].to_i }.max
        last ? last + 1 : 1
      end

      def read_records
        @mutex.synchronize { read_records_unlocked }
      end

      def read_records_unlocked
        return [] unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        data.is_a?(Array) ? data : []
      rescue JSON::ParserError
        raise "Invalid worker queue JSON: #{@path}"
      end

      def update_records
        @mutex.synchronize do
          records = read_records_unlocked
          yield records
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, JSON.pretty_generate(sorted(records)) + "\n")
        end
      end

      def sorted(records)
        records.sort_by { |record| [record["position"].to_i, record["enqueued_at"].to_s, record["id"].to_s] }
      end

      def normalize_positions(records)
        sorted(records).each_with_index do |record, index|
          record["position"] = index + 1
        end
      end
    end
  end
end
