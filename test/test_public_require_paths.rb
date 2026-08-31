require_relative "test_helper"

class TestPublicRequirePaths < KwardTestCase
  def test_plugin_registry_require_path_loads_public_entrypoint
    script = "require 'kward/plugin_registry'; exit(Kward::PluginRegistry ? 0 : 1)"

    assert system(RbConfig.ruby, "-Ilib", "-e", script)
  end
end
