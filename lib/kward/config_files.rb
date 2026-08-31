require "digest"
require "fileutils"
require "json"
require_relative "frontmatter"
require_relative "deep_copy"
require_relative "private_file"
require_relative "workspace/path_guard"
require_relative "permissions/policy"
require_relative "sandbox/policy"
require_relative "shell/kwsh"
require_relative "shell/kwshrc"
require_relative "prompt_interface/editor/editor_mode"
require_relative "prompt_interface/editor/diff_view_mode"
require_relative "prompts/templates"
require_relative "skills/registry"

require_relative "config/core"
require_relative "config/settings"
require_relative "config/prompts"
require_relative "config/extensions"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Resolves Kward configuration, cache, memory, prompt, skill, and plugin
  # paths, and reads/writes the JSON config file used by the CLI and RPC server.
  #
  # This module is the configuration boundary, not a runtime settings cache.
  # Most methods read the filesystem each time so CLI commands and RPC reloads can
  # observe edits made outside the process. Callers that need caching should own
  # invalidation explicitly, as `Client#reload_config` does for provider state.
  #
  # Keep path decisions here. Higher-level code should ask `ConfigFiles` for
  # config, prompt, skill, plugin, cache, memory, and session locations instead of
  # reconstructing `~/.kward` paths independently.
  # @api public
  module ConfigFiles
    extend Core
    extend Settings
    extend Prompts
    extend Extensions
  end
end
