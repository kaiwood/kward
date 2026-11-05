module Kward
  module NativeShell
    # Path traversal uses the same bounded pattern matcher as case and trimming.
    # Recursive ** never follows symlinked directories or visits hidden entries.
    class Glob
      MAX_ENTRIES = 100_000
      MAX_DEPTH = 100

      def initialize(pattern, cwd:, locale:, globstar: false)
        @parts = pattern.split("/", -1)
        @absolute = pattern.start_with?("/")
        @parts.shift if @absolute
        @root = @absolute ? "/" : cwd
        @locale = locale
        @globstar = globstar
        @matches = []
        @visited = 0
      end

      def matches
        root = @root
        prefix = +(@absolute ? "/" : "")
        index = 0
        if root.respond_to?(:access_path)
          # Resolve literal directory prefixes through the retained descriptor,
          # including ../patterns when the current directory has been removed.
          while index < @parts.length - 1 && !Pattern.new(@parts[index], locale: @locale).wildcards?
            prefix << @parts[index].gsub(/\\(.)/m, '\1') << "/"
            index += 1
          end
          opened = Directory.new(prefix, base: root) unless prefix.empty?
          root = (opened || root).access_path
        end
        walk(root, prefix, index, index)
        @matches.uniq.sort { |left, right| @locale.compare(left, right) }
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        []
      ensure
        opened&.close
      end

      private

      def entries(directory)
        Dir.each_child(directory).each_with_object([]) do |name, result|
          @visited += 1
          raise ExpansionError, "pathname expansion exceeds #{MAX_ENTRIES} entries" if @visited > MAX_ENTRIES
          result << name
        end
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        []
      end

      def walk(directory, prefix, index, depth, expanding: false)
        raise ExpansionError, "pathname expansion exceeds #{MAX_DEPTH} directory levels" if depth > MAX_DEPTH
        part = @parts[index]
        if part == ""
          if index == @parts.length - 1
            @matches << prefix unless prefix.empty?
          else
            walk(directory, prefix + "/", index + 1, depth)
          end
          return
        end
        recursive = @globstar && part == "**"
        if recursive
          if index == @parts.length - 1
            @matches << prefix unless prefix.empty? || expanding
          else
            walk(directory, prefix, index + 1, depth)
          end
        end
        matcher = Pattern.new(part, locale: @locale)
        names = matcher.wildcards? ? entries(directory) : [part.gsub(/\\(.)/m, '\1')]
        names.each do |name|
          next if name.start_with?(".") && !part.start_with?(".", "\\.")
          next unless matcher.match?(name)
          path = File.join(directory, name)
          next unless File.exist?(path) || File.symlink?(path)
          if index == @parts.length - 1
            @matches << prefix + name
          elsif File.directory?(path)
            walk(path, prefix + name + "/", index + 1, depth + 1) unless recursive
          end
          if recursive && File.directory?(path)
            if File.symlink?(path)
              @matches << prefix + name + "/" if @parts[(index + 1)..] == [""]
            else
              walk(path, prefix + name + "/", index, depth + 1, expanding: true)
            end
          end
        end
      end
    end
  end
end
