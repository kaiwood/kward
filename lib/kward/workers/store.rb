require "fileutils"
require "json"
require_relative "../config_files"

module Kward
  module Workers
    # JSON-backed metadata store for worker records.
    class Store
      def initialize(path: File.join(ConfigFiles.config_dir, "workers.json"))
        @path = path
        @mutex = Mutex.new
      end

      attr_reader :path

      def upsert(worker)
        record = worker.respond_to?(:to_h) ? worker.to_h : worker.to_h
        update_records do |records|
          index = records.index { |item| item["id"] == record["id"] }
          index ? records[index] = record : records << record
        end
        record
      end

      def list(include_archived: false)
        records = read_records
        records = records.reject { |record| record["status"] == "archived" } unless include_archived
        records.sort_by { |record| record["created_at"].to_s }
      end

      def find(id)
        read_records.find { |record| record["id"] == id.to_s }
      end

      def archive(id)
        record = nil
        update_records do |records|
          index = records.index { |item| item["id"] == id.to_s }
          raise ArgumentError, "Unknown worker: #{id}" unless index

          record = records[index].merge("status" => "archived")
          records[index] = record
        end
        record
      end

      private

      def read_records
        @mutex.synchronize { read_records_unlocked }
      end

      def read_records_unlocked
        return [] unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        data.is_a?(Array) ? data : []
      rescue JSON::ParserError
        raise "Invalid worker store JSON: #{@path}"
      end

      def update_records
        @mutex.synchronize do
          records = read_records_unlocked
          yield records
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, JSON.pretty_generate(records) + "\n")
        end
      end
    end
  end
end
