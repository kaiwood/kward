require "pathname"
require_relative "path_guard"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Resolves safe output paths for transcript exports.
  class ExportPath
    def self.resolve(path, workspace_root:, default_path:, session_dir: nil)
      explicit = path.to_s.strip
      return File.expand_path(default_path) if explicit.empty?

      resolved = File.expand_path(explicit, workspace_root)
      allowed_roots = [workspace_root, session_dir].compact.map { |root| Pathname.new(root).expand_path }
      expanded = Pathname.new(resolved).expand_path
      unless allowed_roots.any? { |root| PathGuard.inside?(expanded, root) }
        raise ArgumentError, "export path outside workspace or session directory: #{path}"
      end

      parent = expanded.dirname
      raise Errno::ENOENT, parent.to_s unless parent.directory?
      raise ArgumentError, "export path outside workspace or session directory: #{path}" if parent.symlink?

      resolved
    end
  end
end
