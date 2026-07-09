require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Cached RubyGems update check for the interactive startup screen.
  class UpdateCheck
    CHECK_INTERVAL_SECONDS = 24 * 60 * 60
    LATEST_VERSION_URL = URI("https://rubygems.org/api/v1/versions/kward/latest.json")

    Notice = Struct.new(:latest_version, keyword_init: true)

    def initialize(current_version:, config: ConfigFiles.read_config, path: ConfigFiles.update_check_cache_path, now: Time.now)
      @current_version = current_version.to_s
      @config = config
      @path = path
      @now = now
    end

    def enabled?
      return false if disabled_by_environment?

      updates = @config["updates"]
      return false if updates.is_a?(Hash) && updates["check"] == false

      true
    end

    def notice
      return nil unless enabled?

      latest_version = cache["latest_version"].to_s
      return nil if latest_version.empty?
      return nil if dismissed_version == latest_version
      return nil unless newer_than_current?(latest_version)

      Notice.new(latest_version: latest_version)
    end

    def refresh_if_stale
      return false unless enabled?
      return false unless stale?

      refresh
    end

    def refresh
      latest_version = fetch_latest_version
      write_cache(cache.merge(
        "checked_at" => @now.utc.iso8601,
        "latest_version" => latest_version
      ))
      true
    rescue StandardError
      false
    end

    private

    def disabled_by_environment?
      value = ENV["KWARD_DISABLE_UPDATE_CHECK"].to_s.strip.downcase
      ["1", "true", "yes", "on"].include?(value)
    end

    def dismissed_version
      cache["dismissed_version"].to_s
    end

    def stale?
      checked_at = Time.iso8601(cache["checked_at"].to_s)
      (@now - checked_at) >= CHECK_INTERVAL_SECONDS
    rescue ArgumentError, TypeError
      true
    end

    def cache
      @cache ||= read_cache
    end

    def read_cache
      return {} unless File.file?(@path)

      data = JSON.parse(File.read(@path))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def write_cache(data)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(data) + "\n")
      @cache = data
    end

    def fetch_latest_version
      request = Net::HTTP::Get.new(LATEST_VERSION_URL)
      request["User-Agent"] = "kward/#{Kward::VERSION}"
      response = Net::HTTP.start(LATEST_VERSION_URL.hostname, LATEST_VERSION_URL.port, use_ssl: true, open_timeout: 2, read_timeout: 2) do |http|
        http.request(request)
      end
      return "" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)["version"].to_s
    rescue JSON::ParserError
      ""
    end

    def newer_than_current?(version)
      Gem::Version.new(version) > Gem::Version.new(@current_version)
    rescue ArgumentError
      false
    end
  end
end
