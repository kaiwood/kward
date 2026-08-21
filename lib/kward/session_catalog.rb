require "json"
require_relative "private_file"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Rebuildable lightweight summaries for persisted session event logs.
  #
  # Session JSONL files remain authoritative. Catalog entries are accepted only
  # while their source fingerprint matches and may be deleted at any time.
  class SessionCatalog
    VERSION = 1
    INDEX_DIRECTORY = ".index"
    FILENAME = "sessions.json"

    def initialize(session_dir:)
      @path = File.join(session_dir, INDEX_DIRECTORY, FILENAME)
      @entries = load_entries
      @dirty = false
    end

    def fetch(path)
      entry = @entries[entry_key(path)]
      return nil unless entry.is_a?(Hash)
      return nil unless entry["source"] == fingerprint(path)

      entry["summary"] if entry["summary"].is_a?(Hash)
    rescue StandardError
      nil
    end

    def write(path, summary, fingerprint: self.fingerprint(path))
      @entries[entry_key(path)] = {
        "source" => fingerprint,
        "summary" => summary
      }
      @dirty = true
    end

    def remove(path)
      @dirty = true if @entries.delete(entry_key(path))
    end

    def retain(paths)
      keys = paths.to_h { |path| [entry_key(path), true] }
      previous_size = @entries.size
      @entries.delete_if { |key, _entry| !keys[key] }
      @dirty = true if @entries.size != previous_size
    end

    def flush
      return unless @dirty

      PrivateFile.write_json(@path, {
        "version" => VERSION,
        "entries" => @entries
      })
      @dirty = false
    rescue StandardError
      nil
    end

    def fingerprint(path)
      stat = File.stat(path)
      {
        "size" => stat.size,
        "inode" => stat.ino,
        "mtimeSeconds" => stat.mtime.to_i,
        "mtimeNanoseconds" => stat.mtime.nsec
      }
    end

    private

    def load_entries
      data = JSON.parse(File.read(@path))
      return {} unless data["version"] == VERSION && data["entries"].is_a?(Hash)

      data["entries"]
    rescue StandardError
      {}
    end

    def entry_key(path)
      File.basename(path)
    end
  end
end
