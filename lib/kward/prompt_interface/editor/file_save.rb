require "tempfile"

module Kward
  class PromptInterface
    # Stages the new contents beside the destination before replacing it.
    module EditorFileSave
      class Conflict < StandardError; end

      module_function

      def read(path)
        return nil unless File.exist?(path) || File.symlink?(path)
        raise IOError, "Not a regular file: #{path}" unless File.file?(path)

        File.read(path)
      end

      def write(path, content, expected:)
        target = File.exist?(path) ? File.realpath(path) : path
        raise Conflict unless read(path) == expected

        mode = if expected.nil?
                 0o666 & ~File.umask
               else
                 File.open(target, "r+") do |file|
                   stat = file.stat
                   raise IOError, "Cannot atomically save a hard-linked file" if stat.nlink > 1

                   stat.mode & 0o777
                 end
               end

        Tempfile.create([".kward-edit-", ".tmp"], File.dirname(target)) do |file|
          file.binmode
          file.write(content)
          file.flush
          file.chmod(mode)
          file.fsync
          file.close
          raise Conflict unless read(path) == expected

          if expected.nil?
            # Do not replace an entry created after the conflict check.
            File.link(file.path, target)
          else
            raise Conflict unless File.realpath(path) == target

            File.rename(file.path, target)
          end
        end
      rescue Errno::EEXIST
        raise Conflict
      end
    end
  end
end
