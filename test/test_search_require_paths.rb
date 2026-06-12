require_relative "test_helper"

class TestSearchRequirePaths < KwardTestCase
  def test_public_search_require_paths_load_implementations
    assert system(RbConfig.ruby, "-Ilib", "-e", "require 'kward/web_search'; require 'kward/code_search'; exit(Kward::WebSearch && Kward::CodeSearch ? 0 : 1)")
  end

  def test_legacy_tools_search_require_paths_still_load_implementations
    assert system(RbConfig.ruby, "-Ilib", "-e", "require 'kward/tools/search/web'; require 'kward/tools/search/code'; exit(Kward::WebSearch && Kward::CodeSearch ? 0 : 1)")
  end
end
