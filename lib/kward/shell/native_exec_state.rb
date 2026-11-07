require_relative "native_directory"

module Kward
  module NativeShell
    module NativeProcess
      # A failed standalone interactive exec must return to a live Ruby process.
      # Shell redirections are persisted separately; these backups protect the
      # process's original IOs (including private descriptors), cwd and signals.
      class ExecState
        attr_reader :signals

        def initialize(descriptors)
          @streams = {}
          @flags = {}
          @signals = {}
          @sync = [STDIN, STDOUT, STDERR].map { |io| io.sync unless io.closed? }
          @mask = File.umask
          @directory = Directory.new(".")
          @directory.protect_descriptors(descriptors)
          descriptors.each do |fd|
            flags = FCNTL.call(fd, Fcntl::F_GETFD, 0)
            if flags < 0
              raise SystemCallError.new("fcntl", Fiddle.last_error) unless Fiddle.last_error == Errno::EBADF::Errno
              @streams[fd] = nil
              next
            end
            copy = FCNTL.call(fd, Fcntl::F_DUPFD, [32, descriptors.max + 1].max)
            raise SystemCallError.new("dup", Fiddle.last_error) if copy < 0
            @streams[fd] = IO.for_fd(copy)
            @streams[fd].close_on_exec = true
            @flags[fd] = [flags, FCNTL.call(fd, Fcntl::F_GETFL, 0)]
          end
          complete = true
        ensure
          close unless complete
        end

        def restore
          @streams.each do |fd, source|
            if fd < 3
              standard = [STDIN, STDOUT, STDERR][fd]
              if source
                standard.reopen(source)
                standard.sync = @sync[fd]
              else
                standard.close unless standard.closed?
              end
            elsif source
              raise SystemCallError.new("dup2", Fiddle.last_error) if DUP2.call(source.fileno, fd) < 0
            else
              CLOSE.call(fd)
            end
            next unless source
            descriptor_flags, file_flags = @flags.fetch(fd)
            raise SystemCallError.new("fcntl", Fiddle.last_error) if FCNTL.call(fd, Fcntl::F_SETFD, descriptor_flags) < 0
            raise SystemCallError.new("fcntl", Fiddle.last_error) if FCNTL.call(fd, Fcntl::F_SETFL, file_flags) < 0
          end
          @directory.enter
          File.umask(@mask)
          @signals.each { |name, handler| Signal.trap(name, handler || "DEFAULT") }
        rescue StandardError => e
          # Continuing with corrupt descriptors could expose private resources.
          raise SystemExit.new(126, "exec recovery failed: #{e.message}")
        end

        def close
          @streams.each_value { |io| io.close if io && !io.closed? }
          @directory&.close
        end
      end
    end
  end
end
