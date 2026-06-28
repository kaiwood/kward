require "fileutils"
require "json"
require "time"
require_relative "config_files"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Workspace-scoped JSONL persistence for terminal prompt history.
  class PromptHistory
    DEFAULT_LIMIT = 1_000

    Entry = Struct.new(:value, :timestamp, keyword_init: true)

    def initialize(config_dir: ConfigFiles.config_dir, cwd: Dir.pwd, limit: DEFAULT_LIMIT, kind: "prompt")
      @config_dir = config_dir
      @cwd = ConfigFiles.canonical_workspace_root(cwd)
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
      @kind = kind.to_s.empty? ? "prompt" : kind.to_s
    end

    attr_reader :cwd, :limit, :kind

    def values
      entries.map(&:value)
    end

    def append(value)
      text = value.to_s
      return false if text.strip.empty?

      existing = entries
      return false if existing.last&.value == text

      write_entries((existing + [Entry.new(value: text, timestamp: Time.now.utc.iso8601(3))]).last(limit))
      true
    end

    def path
      ConfigFiles.prompt_history_path(@cwd, config_dir: @config_dir, kind: @kind)
    end

    private

    def entries
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        record = JSON.parse(line)
        value = record["value"].to_s
        next if value.strip.empty?

        Entry.new(value: value, timestamp: record["timestamp"].to_s)
      rescue JSON::ParserError
        nil
      end.last(limit)
    rescue Errno::ENOENT
      []
    end

    def write_entries(entries)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(history_header))
        file.write("\n")
        entries.each do |entry|
          file.write(JSON.generate({ type: "prompt_history", version: 1, timestamp: entry.timestamp || Time.now.utc.iso8601(3), value: entry.value }))
          file.write("\n")
        end
      end
      File.chmod(0o600, path)
    end

    def history_header
      {
        type: "prompt_history_header",
        version: 1,
        kind: @kind,
        workspace: @cwd,
        workspaceHash: File.basename(path, ".jsonl"),
        limit: limit
      }
    end
  end
end
