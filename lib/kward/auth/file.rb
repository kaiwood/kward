require_relative "../private_file"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Shared private-file storage helpers for auth credentials.
  module AuthFile
    module_function

    def write_json(path, data)
      PrivateFile.write_json(path, data)
    end
  end
end
