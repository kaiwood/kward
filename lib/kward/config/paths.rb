module Kward
  # Shared user configuration location; resolving it does not load any config.
  module ConfigPaths
    def self.config_dir
      path = ENV["KWARD_CONFIG_PATH"]
      return File.expand_path(File.dirname(path)) if path && !path.empty?

      File.expand_path("~/.kward")
    end
  end
end
