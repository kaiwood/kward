require "fileutils"
require "net/http"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "uri"
require "zlib"
require_relative "config_files"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Installs Kward's starter prompt/instruction files into the user config dir.
  class StarterPackInstaller
    VERSION = "v1.0.1"
    ARCHIVE_URL = "https://codeload.github.com/kaiwood/kward-starter-pack/tar.gz/refs/tags/#{VERSION}".freeze
    ALLOWED_FILES = ["PRINCIPLES.md"].freeze
    ALLOWED_PREFIXES = ["prompts/", "skills/"].freeze
    Result = Struct.new(:installed, :skipped, keyword_init: true)

    def self.install(**kwargs)
      new(**kwargs).install
    end

    def initialize(config_dir: ConfigFiles.config_dir, archive_url: ARCHIVE_URL, downloader: nil)
      @config_dir = File.expand_path(config_dir)
      @archive_url = archive_url
      @downloader = downloader || method(:download)
    end

    def install
      archive = @downloader.call(@archive_url)
      installed = []
      skipped = []

      Dir.mktmpdir("kward-starter-pack") do |dir|
        files = extract_allowed_files(archive, dir)
        files.each do |relative_path, source_path|
          destination = destination_path(relative_path)
          if File.exist?(destination)
            skipped << relative_path
            next
          end

          FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
          File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write(File.binread(source_path))
          end
          installed << relative_path
        end
      end

      Result.new(installed: installed, skipped: skipped)
    end

    private

    def download(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
        http.get(uri.request_uri)
      end
      raise "Starter pack download failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error => e
      raise "Starter pack download failed: #{e.message}"
    end

    def extract_allowed_files(archive, dir)
      files = []
      Zlib::GzipReader.wrap(StringIO.new(archive)) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            next unless entry.file?

            relative_path = starter_pack_relative_path(entry.full_name)
            next unless allowed_file?(relative_path)

            output = File.join(dir, relative_path)
            FileUtils.mkdir_p(File.dirname(output), mode: 0o700)
            File.binwrite(output, entry.read)
            files << [relative_path, output]
          end
        end
      end
      files
    rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError => e
      raise "Starter pack archive could not be read: #{e.message}"
    end

    def starter_pack_relative_path(path)
      parts = path.to_s.split("/")
      raise "Unsafe starter pack archive path: #{path}" if parts.any? { |part| part.empty? || part == "." || part == ".." }
      raise "Unsafe starter pack archive path: #{path}" if path.start_with?("/")

      parts[1..]&.join("/").to_s
    end

    def allowed_file?(relative_path)
      ALLOWED_FILES.include?(relative_path) || ALLOWED_PREFIXES.any? { |prefix| relative_path.start_with?(prefix) }
    end

    def destination_path(relative_path)
      path = File.expand_path(File.join(@config_dir, relative_path))
      root = @config_dir.end_with?(File::SEPARATOR) ? @config_dir : "#{@config_dir}#{File::SEPARATOR}"
      raise "Unsafe starter pack destination: #{relative_path}" unless path.start_with?(root)

      path
    end
  end
end
