require "rubygems"
require_relative "test_helper"

class TestGemspec < KwardTestCase
  def test_public_metadata_points_to_the_product_site_and_source_repository
    specification = Gem::Specification.load(File.expand_path("../kward.gemspec", __dir__))

    assert_equal "An extensible Ruby coding agent for your terminal.", specification.summary
    refute_includes specification.description, "experimental"
    assert_equal "https://kaiwood.github.io/kward/", specification.homepage
    assert_equal "https://kaiwood.github.io/kward/", specification.metadata.fetch("documentation_uri")
    assert_equal "https://github.com/kaiwood/kward", specification.metadata.fetch("source_code_uri")
    assert_equal "true", specification.metadata.fetch("rubygems_mfa_required")
  end
end
