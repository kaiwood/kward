require_relative "test_helper"
require "rubygems/package"
require "zlib"

class TestStarterPackInstaller < KwardTestCase
  def test_installs_allowed_files_preserving_layout_and_skips_existing_files
    Dir.mktmpdir do |config_dir|
      existing = File.join(config_dir, "prompts", "plan.md")
      FileUtils.mkdir_p(File.dirname(existing))
      File.write(existing, "mine")

      archive = starter_pack_archive(
        "kward-starter-pack-1.0.0/AGENTS.md" => "agents",
        "kward-starter-pack-1.0.0/prompts/plan.md" => "starter plan",
        "kward-starter-pack-1.0.0/prompts/research.md" => "research",
        "kward-starter-pack-1.0.0/README.md" => "readme",
        "kward-starter-pack-1.0.0/LICENSE" => "license"
      )

      result = Kward::StarterPackInstaller.new(config_dir: config_dir, downloader: ->(_url) { archive }).install

      assert_equal ["AGENTS.md", "prompts/research.md"], result.installed.sort
      assert_equal ["prompts/plan.md"], result.skipped
      assert_equal "agents", File.read(File.join(config_dir, "AGENTS.md"))
      assert_equal "mine", File.read(existing)
      assert_equal "research", File.read(File.join(config_dir, "prompts", "research.md"))
      refute_path_exists File.join(config_dir, "README.md")
      refute_path_exists File.join(config_dir, "LICENSE")
    end
  end

  def test_download_failure_does_not_write_starter_pack_files
    Dir.mktmpdir do |config_dir|
      installer = Kward::StarterPackInstaller.new(config_dir: config_dir, downloader: ->(_url) { raise "offline" })

      error = assert_raises(RuntimeError) { installer.install }

      assert_equal "offline", error.message
      refute_path_exists File.join(config_dir, "AGENTS.md")
      refute_path_exists File.join(config_dir, "prompts")
    end
  end

  def test_rejects_unsafe_archive_paths
    Dir.mktmpdir do |config_dir|
      archive = starter_pack_archive("../evil/AGENTS.md" => "bad")
      installer = Kward::StarterPackInstaller.new(config_dir: config_dir, downloader: ->(_url) { archive })

      error = assert_raises(RuntimeError) { installer.install }

      assert_match(/Unsafe starter pack archive path/, error.message)
      refute_path_exists File.join(config_dir, "AGENTS.md")
    end
  end

  private

  def starter_pack_archive(entries)
    StringIO.new.tap do |io|
      Zlib::GzipWriter.wrap(io) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          entries.each do |name, body|
            tar.add_file_simple(name, 0o644, body.bytesize) { |file| file.write(body) }
          end
        end
      end
    end.string
  end
end
