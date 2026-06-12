require_relative "test_helper"

class TestSearchRequirePaths < KwardTestCase
  def test_tools_search_require_paths_load_implementations
    assert system(RbConfig.ruby, "-Ilib", "-e", "require 'kward/tools/search/web'; require 'kward/tools/search/code'; exit(Kward::WebSearch && Kward::CodeSearch ? 0 : 1)")
  end
end
