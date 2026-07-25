require "fileutils"
require "json"
require "tempfile"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Writes sensitive JSON files with private filesystem permissions.
  module PrivateFile
    module_function

    def write_json(path, data)
      path = File.expand_path(path)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory, mode: 0o700)

      Tempfile.create([".#{File.basename(path)}.", ".tmp"], directory, mode: 0o600) do |file|
        file.write(JSON.pretty_generate(data))
        file.write("\n")
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path)
      end
    end
  end
end
