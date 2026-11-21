require "fileutils"
require "securerandom"
require "tmpdir"
require_relative "model/codex_images"
require_relative "shell/native_directory"

module Kward
  # Owns unsaved preview bytes. Only the frontend can export or discard them.
  class GeneratedImages
    Error = Class.new(StandardError)
    Preview = Struct.new(:id, :filename, :root, :size, keyword_init: true)
    Entry = Struct.new(:owner, :preview, :path, keyword_init: true)
    MAX_PREVIEWS = 16
    FETCH_CHUNK_BYTES = 256 * 1024
    LOCK_FLAGS = File::RDWR | File::CREAT | File::NOFOLLOW

    def initialize(base: File.join(Dir.tmpdir, "kward-images-#{Process.uid}"))
      @base = base
      @entries = {}
      @mutex = Mutex.new
      reap_crashed_runs
    end

    def add(owner, bytes, cancellation: nil)
      raise Error, "Invalid or oversized PNG." unless CodexImages.valid_png?(bytes)

      @mutex.synchronize do
        cancellation&.raise_if_cancelled!
        raise Error, "Image preview storage is closed." if @closed
        raise Error, "Too many pending images; discard a preview before generating another." if @entries.size >= MAX_PREVIEWS

        initialize_run unless @run
        id = SecureRandom.hex(16)
        preview = Preview.new(id: id, filename: "kward-image-#{id[0, 8]}.png", root: File.realpath(owner.workspace_root), size: bytes.bytesize).freeze
        path = File.join(@run, "#{id}.png")
        begin
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.binmode.write(bytes) }
          cancellation&.raise_if_cancelled!
          @entries[id] = Entry.new(owner: owner, preview: preview, path: path)
        ensure
          FileUtils.rm_f(path) unless @entries.key?(id)
        end
        preview
      end
    rescue SystemCallError
      raise Error, "Could not store the generated image preview."
    end

    def path(owner, id)
      @mutex.synchronize { entry_for(owner, id).path }
    end

    def fetch(owner, id, offset: 0)
      raise Error, "Invalid image offset." unless offset.is_a?(Integer) && offset >= 0

      @mutex.synchronize do
        entry = entry_for(owner, id)
        raise Error, "Invalid image offset." if offset > entry.preview.size
        return [entry.preview, "".b] if offset == entry.preview.size

        bytes = File.binread(entry.path, FETCH_CHUNK_BYTES, offset)
        raise Error, "Image preview is unavailable or has been discarded." unless bytes

        [entry.preview, bytes]
      end
    rescue SystemCallError
      raise Error, "Image preview is unavailable or has been discarded."
    end

    def save_to_project(owner, id, directory = ".")
      export(owner, id, directory, project: true)
    end

    def save_to_downloads(owner, id)
      export(owner, id, downloads_directory)
    rescue SystemCallError
      raise Error, "Could not locate the Downloads folder."
    end

    def discard(owner, id)
      @mutex.synchronize do
        entry = entry_for(owner, id)
        FileUtils.rm_f(entry.path)
        @entries.delete(id)
      end
      true
    end

    def discard_owner(owner)
      @mutex.synchronize do
        @entries.delete_if do |_id, entry|
          next false unless entry.owner.equal?(owner)

          FileUtils.rm_f(entry.path)
          true
        end
      end
    end

    def close
      @mutex.synchronize do
        @closed = true
        @entries.clear
        with_base_lock { FileUtils.remove_entry_secure(@run) } if @run && File.directory?(@run)
      ensure
        @run = nil
        @run_lock&.close
        @run_lock = nil
      end
    rescue Error, SystemCallError
      # A later instance will reap the run if removal could not finish.
      nil
    end

    private

    def initialize_run
      begin
        Dir.mkdir(@base, 0o700)
      rescue Errno::EEXIST
        nil
      end
      with_base_lock do
        run = Dir.mktmpdir("run-", @base)
        run_lock = File.open(File.join(run, "lock"), LOCK_FLAGS, 0o600)
        run_lock.flock(File::LOCK_EX)
        @run, @run_lock = run, run_lock
      end
    end

    def reap_crashed_runs
      with_base_lock { remove_stale_runs }
    rescue Error, SystemCallError
      # The directory may not exist yet. Report storage errors on generation.
      nil
    end

    def with_base_lock
      stat = File.lstat(@base)
      raise Error, "Image preview directory is not private." unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?

      File.open(File.join(@base, "lock"), LOCK_FLAGS, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def remove_stale_runs
      Dir.each_child(@base) do |name|
        next unless name.start_with?("run-")

        path = File.join(@base, name)
        next unless File.lstat(path).directory?

        File.open(File.join(path, "lock"), LOCK_FLAGS, 0o600) do |lock|
          FileUtils.remove_entry_secure(path) if lock.flock(File::LOCK_EX | File::LOCK_NB)
        end
      rescue SystemCallError
        next
      end
    end

    def entry_for(owner, id)
      entry = @entries[id]
      raise Error, "Image preview is unavailable or has been discarded." unless entry&.owner&.equal?(owner)

      entry
    end

    def export(owner, id, directory, project: false)
      @mutex.synchronize do
        entry = entry_for(owner, id)
        root = entry.preview.root if project
        destination = File.expand_path(directory.to_s, root)
        handle = NativeShell::Directory.new(destination)
        begin
          resolved = handle.physical_path
          if root && !within?(resolved, root)
            raise Error, "Choose a directory inside the project."
          end

          write_exclusively(handle, resolved, entry)
        ensure
          handle.close
        end
      end
    rescue IOError, SystemCallError, ArgumentError
      raise Error, "Could not save the image. Choose an existing, writable directory."
    end

    def within?(path, root)
      path == root || path.start_with?(root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}")
    end

    def write_exclusively(handle, directory, entry)
      stem = File.basename(entry.preview.filename, ".png")
      1000.times do |index|
        name = index.zero? ? "#{stem}.png" : "#{stem}-#{index + 1}.png"
        path = File.join(directory, name)
        flags = File::WRONLY | File::CREAT | File::EXCL
        output = handle.open_file(name, flags)
        begin
          stat = output.stat
          output.binmode
          IO.copy_stream(entry.path, output)
          output.close
        rescue IOError, SystemCallError
          remove_failed_export(path, stat) if stat
          raise
        ensure
          output.close unless output.closed?
        end
        return path
      rescue Errno::EEXIST
        next
      end
      raise Error, "Could not find an unused image filename."
    end

    def remove_failed_export(path, stat)
      current = File.lstat(path)
      File.unlink(path) if stat.ino == current.ino && stat.dev == current.dev
    rescue SystemCallError
      nil
    end

    def downloads_directory
      home = Dir.home
      config = File.join(ENV.fetch("XDG_CONFIG_HOME", File.join(home, ".config")), "user-dirs.dirs")
      if RUBY_PLATFORM.include?("linux") && File.file?(config)
        value = File.read(config, 16_384)[/^XDG_DOWNLOAD_DIR="(\$HOME(?:\/[^"\n]*)?|\/[^"\n]*)"$/, 1]
        return value.sub(/\A\$HOME(?=\/|\z)/) { home } if value
      end
      File.join(home, "Downloads")
    end
  end
end
