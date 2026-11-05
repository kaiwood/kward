require "fiddle"
require "fcntl"

module Kward
  module NativeShell
    # Owns directory identity independently of the shell's logical PWD. Never
    # changes the host cwd; only an exec-bound child may enter this descriptor.
    class Directory
      OPENAT = Fiddle::Function.new(Fiddle::Handle::DEFAULT["openat"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VARIADIC], Fiddle::TYPE_INT)
      FACCESSAT = Fiddle::Function.new(Fiddle::Handle::DEFAULT["faccessat"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      FCHDIR = Fiddle::Function.new(Fiddle::Handle::DEFAULT["fchdir"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)

      # Darwin sys/fcntl.h: O_SEARCH | O_CLOEXEC, AT_FDCWD, AT_EACCESS.
      # Linux asm-generic/fcntl.h: O_PATH | O_DIRECTORY | O_CLOEXEC. O_PATH
      # needs a separate effective-ID search-permission check on the directory.
      FLAGS, CLOEXEC, AT_FDCWD, AT_EACCESS = if RUBY_PLATFORM.include?("darwin")
        [0x41100000, 0x01000000, -2, 0x10]
      elsif RUBY_PLATFORM.include?("linux")
        [0x290000, 0x80000, -100, 0x200]
      else
        raise LoadError, "native directory handles require macOS or Linux"
      end

      def initialize(path, base: nil)
        raise ArgumentError, "NUL bytes are not allowed in directory paths" if path.include?("\0")
        fd = OPENAT.call(base ? base.fileno : AT_FDCWD, path, FLAGS, Fiddle::TYPE_INT, 0)
        raise SystemCallError.new(path, Fiddle.last_error) if fd < 0
        @handle = IO.for_fd(fd)
        if FACCESSAT.call(fd, ".", 1, AT_EACCESS) < 0
          error = Fiddle.last_error
          close
          raise SystemCallError.new(path, error)
        end
      end

      def initialize_copy(other)
        super
        @handle = other.handle.dup
        @handle.close_on_exec = true
      end

      def fileno
        @handle.fileno
      end

      def close
        @handle.close unless @handle.closed?
      end

      def closed?
        @handle.closed?
      end

      def same?(path)
        stat = File.stat(path)
        current = @handle.stat
        stat.dev == current.dev && stat.ino == current.ino
      rescue SystemCallError
        false
      end

      def physical_path
        File.realpath(access_path)
      end

      def access_path
        path = if RUBY_PLATFORM.include?("darwin")
          # F_GETPATH uses the kernel's MAXPATHLEN-sized output buffer.
          buffer = "\0" * 1024
          @handle.fcntl(50, buffer)
          buffer.split("\0", 2).first
        else
          File.readlink("/proc/self/fd/#{fileno}")
        end
        raise Errno::ENOENT, "current directory has no pathname" unless same?(path)
        path
      end

      def resolve(path)
        return path if path.start_with?("/")
        # Do not expand_path here: symlink/.. must be resolved by the kernel.
        File.join(access_path, path.delete_prefix("./"))
      end

      def open_file(path, mode = "r")
        raise ArgumentError, "NUL bytes are not allowed in file paths" if path.include?("\0")
        flags = mode.is_a?(Integer) ? mode : { "r" => File::RDONLY, "w" => File::WRONLY | File::CREAT | File::TRUNC, "a" => File::WRONLY | File::CREAT | File::APPEND }.fetch(mode)
        fd = OPENAT.call(fileno, path, flags | CLOEXEC, Fiddle::TYPE_INT, 0o666)
        raise SystemCallError.new(path, Fiddle.last_error) if fd < 0
        file = IO.for_fd(fd)
        return file unless block_given?
        begin
          yield file
        ensure
          file.close
        end
      end

      def protect_descriptors(descriptors)
        return unless descriptors.include?(fileno)
        replacement = IO.for_fd(@handle.fcntl(Fcntl::F_DUPFD, [32, descriptors.max + 1].max))
        replacement.close_on_exec = true
        @handle.close
        @handle = replacement
      end

      def enter
        raise SystemCallError.new("fchdir", Fiddle.last_error) if FCHDIR.call(fileno) < 0
      end

      protected

      attr_reader :handle
    end
  end
end
