require_relative "test_helper"

class TestUpdateCheck < KwardTestCase
  class FakeUpdateCheck < Kward::UpdateCheck
    attr_reader :fetch_count

    def initialize(*args, latest_version:, **kwargs)
      super(*args, **kwargs)
      @latest_version = latest_version
      @fetch_count = 0
    end

    private

    def fetch_latest_version
      @fetch_count += 1
      @latest_version
    end
  end

  def test_notice_can_refresh_stale_cache_before_returning_notice
    Dir.mktmpdir do |dir|
      path = File.join(dir, "update_check.json")
      checker = FakeUpdateCheck.new(
        current_version: "1.0.0",
        config: {},
        path: path,
        now: Time.utc(2026, 7, 9),
        latest_version: "1.1.0"
      )

      notice = checker.notice(refresh: true)

      assert_equal "1.1.0", notice.latest_version
      assert_equal 1, checker.fetch_count
      cache = JSON.parse(File.read(path))
      assert_equal "1.1.0", cache["latest_version"]
    end
  end

  def test_notice_without_refresh_uses_only_cached_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "update_check.json")
      checker = FakeUpdateCheck.new(
        current_version: "1.0.0",
        config: {},
        path: path,
        now: Time.utc(2026, 7, 9),
        latest_version: "1.1.0"
      )

      assert_nil checker.notice
      assert_equal 0, checker.fetch_count
      refute File.exist?(path)
    end
  end

  def test_disabled_update_check_does_not_refresh
    Dir.mktmpdir do |dir|
      path = File.join(dir, "update_check.json")
      checker = FakeUpdateCheck.new(
        current_version: "1.0.0",
        config: { "updates" => { "check" => false } },
        path: path,
        now: Time.utc(2026, 7, 9),
        latest_version: "1.1.0"
      )

      assert_nil checker.notice(refresh: true)
      assert_equal 0, checker.fetch_count
      refute File.exist?(path)
    end
  end
end
