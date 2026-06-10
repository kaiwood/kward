require_relative "../private_file"

module Kward
  module AuthFile
    module_function

    def write_json(path, data)
      PrivateFile.write_json(path, data)
    end
  end
end
