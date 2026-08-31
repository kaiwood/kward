require "pathname"
require_relative "../workspace/workspace"
require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Builds a compact, task-shaped bundle from likely workspace files.
    class ContextForTask < Base
      DEFAULT_BUDGET = 4_000
      MAX_BUDGET = 20_000
      MAX_FILES = 8
      MAX_MATCHES_PER_FILE = 8
      DEFAULT_EXTENSIONS = %w[.rb .js .jsx .ts .tsx .py .go .rs .java .cs .cpp .c .h .hpp .md .yml .yaml .json .toml].freeze
      SKIP_DIRECTORIES = %w[.git .yardoc _yardoc node_modules vendor tmp log coverage dist build .bundle].freeze

      # Builds the tool schema and stores the execution dependency.
      def initialize(workspace:)
        @workspace = workspace
        super(
          "context_for_task",
          "Build focused workspace context for a task from outlines and matching excerpts within a byte budget.",
          properties: {
            budget: { type: "integer", description: "Approximate byte budget for the returned context. Default 4000, maximum 20000." },
            paths: { type: "array", items: { type: "string" }, description: "Optional workspace-relative files or directories to focus." },
            task: { type: "string", description: "Task or question to gather context for." }
          },
          required: ["task"]
        )
      end

      # Executes focused context retrieval.
      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        task = argument(args, :task, "").to_s.strip
        return "Error: task is required" if task.empty?

        budget = normalized_budget(argument(args, :budget))
        return budget if budget.is_a?(String)

        focus_paths = Array(argument(args, :paths, [])).map(&:to_s).reject(&:empty?)
        files = candidate_files(focus_paths, cancellation: cancellation)
        return "No readable candidate files found for focused context." if files.empty?

        terms = search_terms(task)
        ranked = rank_files(files, terms)
        return "No matching candidate files found for focused context." if ranked.empty?

        render_context(task: task, budget: budget, terms: terms, ranked: ranked, cancellation: cancellation)
      rescue SecurityError, Errno::ENOENT => e
        "Error: #{e.message}"
      end

      private

      def normalized_budget(value)
        return DEFAULT_BUDGET if value.nil?

        budget = value.to_i
        return "Error: budget must be positive" unless budget.positive?

        [budget, MAX_BUDGET].min
      end

      def candidate_files(paths, cancellation:)
        roots = paths.empty? ? [@workspace.root.to_s] : paths.map { |path| @workspace.resolved_path(path) }
        files = roots.flat_map do |path|
          cancellation&.raise_if_cancelled!
          File.directory?(path) ? files_under(path, cancellation: cancellation) : [path]
        end
        files.uniq.select { |path| readable_context_file?(path) }.first(MAX_FILES * 8)
      end

      def files_under(root, cancellation:)
        files = []
        stack = [root]
        until stack.empty? || files.length >= MAX_FILES * 8
          cancellation&.raise_if_cancelled!
          current = stack.pop
          next if skipped_directory?(current)

          entries = Dir.children(current).sort.map { |entry| File.join(current, entry) }
          entries.each do |entry|
            if File.directory?(entry)
              stack << entry
            else
              files << entry if readable_context_file?(entry)
            end
          end
        end
        files
      end

      def readable_context_file?(path)
        return false unless File.file?(path)
        return false if File.size(path) > Workspace::MAX_FILE_BYTES
        return false unless DEFAULT_EXTENSIONS.include?(File.extname(path)) || File.basename(path) == "Gemfile"

        sample = File.open(path, "rb") { |file| file.read(4096).to_s }
        !sample.include?("\x00")
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      def skipped_directory?(path)
        SKIP_DIRECTORIES.include?(File.basename(path))
      end

      def search_terms(task)
        task.scan(/[A-Za-z_][A-Za-z0-9_]{2,}/).map(&:downcase).reject { |term| stopword?(term) }.uniq.first(20)
      end

      def stopword?(term)
        %w[the and for with from this that into when where what why how fix add update change implement review debug explain failing failure error issue].include?(term)
      end

      def rank_files(files, terms)
        scored = files.map do |path|
          content = File.read(path)
          relative = relative_path(path)
          score = score_file(relative, content, terms)
          { path: path, relative: relative, content: content, score: score }
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end.compact
        filtered = terms.empty? ? scored : scored.select { |file| file[:score].positive? }
        filtered.sort_by { |file| [-file[:score], file[:relative]] }.first(MAX_FILES)
      end

      def score_file(relative, content, terms)
        haystack = "#{relative}\n#{content}".downcase
        terms.sum { |term| haystack.scan(term).length } + (terms.any? { |term| relative.downcase.include?(term) } ? 5 : 0)
      end

      def render_context(task:, budget:, terms:, ranked:, cancellation:)
        lines = ["# Focused context", "- Task: #{task}", "- Budget: #{budget} bytes", "- Search terms: #{terms.empty? ? '(none)' : terms.join(', ')}", ""]
        used = lines.join("\n").bytesize

        ranked.each do |file|
          cancellation&.raise_if_cancelled!
          section = file_section(file, terms)
          break if used + section.bytesize > budget && lines.length > 5

          if used + section.bytesize > budget
            remaining = budget - used
            break if remaining < 200

            section = section.byteslice(0, remaining).to_s.scrub << "\n[Context budget reached.]"
          end
          lines << section
          used += section.bytesize
        end

        lines.join("\n")
      end

      def file_section(file, terms)
        outline = @workspace.summarize_file_structure(file[:relative])
        matches = matching_excerpt(file[:content], terms)
        parts = ["## #{file[:relative]}", "- Score: #{file[:score]}"]
        parts << outline unless outline.start_with?("No recognizable source structure")
        parts << matches unless matches.empty?
        parts.join("\n") << "\n"
      end

      def matching_excerpt(content, terms)
        return "" if terms.empty?

        lines = content.split("\n", -1)
        indexes = matching_indexes(lines, terms)
        return "" if indexes.empty?

        selected = indexes.flat_map { |index| ([index - 2, 0].max..[index + 2, lines.length - 1].min).to_a }.uniq.sort
        render_excerpt(lines, selected)
      end

      def matching_indexes(lines, terms)
        indexes = []
        lines.each_with_index do |line, index|
          lower = line.downcase
          indexes << index if terms.any? { |term| lower.include?(term) }
          break if indexes.length >= MAX_MATCHES_PER_FILE
        end
        indexes
      end

      def render_excerpt(lines, selected)
        output = ["### Matching excerpts"]
        previous = nil
        selected.each do |index|
          output << "..." if previous && index > previous + 1
          output << "%4d: %s" % [index + 1, lines[index]]
          previous = index
        end
        output.join("\n")
      end

      def relative_path(path)
        Pathname.new(path).relative_path_from(@workspace.root).to_s
      end
    end
  end
end
