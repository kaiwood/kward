require "digest"
require "json"
require_relative "config_files"
require_relative "private_file"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Persists the terminal UI's open session tabs per workspace.
  class TabStore
    def initialize(config_dir: ConfigFiles.config_dir, cwd: Dir.pwd)
      @config_dir = config_dir
      @cwd = File.expand_path(cwd)
    end

    def load
      return { "session_paths" => [], "active_index" => 0 } unless File.file?(path)

      data = JSON.parse(File.read(path))
      paths = Array(data["session_paths"]).map(&:to_s).reject(&:empty?)
      active_index = data["active_index"].to_i
      { "session_paths" => paths, "active_index" => active_index }
    rescue JSON::ParserError
      { "session_paths" => [], "active_index" => 0 }
    end

    def save(session_paths:, active_index:)
      paths = Array(session_paths).map(&:to_s).reject(&:empty?)
      PrivateFile.write_json(path, {
        "cwd" => @cwd,
        "session_paths" => paths,
        "active_index" => [[active_index.to_i, 0].max, [paths.length - 1, 0].max].min
      })
    end

    def path
      File.join(@config_dir, "tabs", "#{workspace_key}.json")
    end

    private

    def workspace_key
      Digest::SHA256.hexdigest(@cwd)[0, 24]
    end
  end
end
