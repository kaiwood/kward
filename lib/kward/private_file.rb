require "fileutils"
require "json"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Writes sensitive JSON files with private filesystem permissions.
  module PrivateFile
    module_function

    def write_json(path, data)
      path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.pretty_generate(data))
        file.write("\n")
      end
      File.chmod(0o600, path)
    end
  end
end
