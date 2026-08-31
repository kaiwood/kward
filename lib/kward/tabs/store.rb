require "digest"
require "json"
require_relative "../config_files"
require_relative "../private_file"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Persists the terminal UI's open tabs per workspace.
  class TabStore
    VERSION = 2

    def initialize(config_dir: ConfigFiles.config_dir, cwd: Dir.pwd)
      @config_dir = config_dir
      @cwd = File.expand_path(cwd)
    end

    def load
      return empty_state unless File.file?(path)

      data = JSON.parse(File.read(path))
      return typed_state(data) if data["tabs"].is_a?(Array)

      legacy_state(data)
    rescue JSON::ParserError
      empty_state
    end

    # `session_paths` remains supported for callers and layouts written before
    # typed tab descriptors were introduced.
    def save(session_paths: nil, tabs: nil, active_index:, labels: [])
      tabs ||= Array(session_paths).filter_map.with_index do |session_path, index|
        path = session_path.to_s
        next if path.empty?

        {
          "kind" => "session",
          "session_path" => path,
          "label" => Array(labels)[index].to_s
        }
      end
      tabs = normalize_tabs(tabs)
      PrivateFile.write_json(path, {
        "version" => VERSION,
        "cwd" => @cwd,
        "tabs" => tabs,
        "active_index" => [[active_index.to_i, 0].max, [tabs.length - 1, 0].max].min
      })
    end

    def path
      File.join(@config_dir, "tabs", "#{workspace_key}.json")
    end

    private

    def empty_state
      { "tabs" => [], "session_paths" => [], "labels" => [], "active_index" => 0 }
    end

    def typed_state(data)
      tabs = normalize_tabs(data["tabs"])
      state_for(tabs, data["active_index"])
    end

    def legacy_state(data)
      paths = Array(data["session_paths"]).map(&:to_s).reject(&:empty?)
      labels = Array(data["labels"]).map(&:to_s)
      tabs = paths.each_with_index.map do |session_path, index|
        { "kind" => "session", "session_path" => session_path, "label" => labels[index].to_s }
      end
      state_for(tabs, data["active_index"])
    end

    def state_for(tabs, active_index)
      {
        "tabs" => tabs,
        "session_paths" => tabs.filter_map { |tab| tab["session_path"] if tab["kind"] == "session" },
        "labels" => tabs.map { |tab| tab["label"].to_s },
        "active_index" => [[active_index.to_i, 0].max, [tabs.length - 1, 0].max].min
      }
    end

    def normalize_tabs(tabs)
      session_paths = {}

      Array(tabs).filter_map do |tab|
        next unless tab.is_a?(Hash)

        normalized = tab.transform_keys(&:to_s)
        kind = normalized["kind"].to_s
        next if kind.empty?
        next if kind == "session" && normalized["session_path"].to_s.empty?

        if kind == "session"
          session_path = File.expand_path(normalized["session_path"].to_s, @cwd)
          next if session_paths[session_path]

          session_paths[session_path] = true
        end

        normalized
      end
    end

    def workspace_key
      Digest::SHA256.hexdigest(@cwd)[0, 24]
    end
  end
end
