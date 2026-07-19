require "fileutils"
require "json"
require "tempfile"
require "yaml"
require_relative "../compaction/token_estimator"
require_relative "../config_files"
require_relative "../message_access"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Skills
    # Generates and persists reviewed personal skills from saved session branches.
    class Capture
      Draft = Struct.new(:content, :source_path, :name, :description, keyword_init: true)

      class Error < StandardError; end
      class SourceTooLargeError < Error; end
      class InvalidDraftError < Error; end
      class ConflictError < Error; end

      OUTPUT_TOKEN_RESERVE = 4_096
      PROMPT_TOKEN_RESERVE = 1_024
      NAME_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

      def initialize(session_store:, client:, config_dir: ConfigFiles.config_dir, token_estimator: Compaction::TokenEstimator.new)
        @session_store = session_store
        @client = client
        @config_dir = config_dir
        @token_estimator = token_estimator
      end

      def generate(session_path, cancellation: nil)
        source = @session_store.capture_branch(session_path)
        raise Error, "Session has no active branch to capture" if source[:entries].empty?

        source_json = JSON.pretty_generate(source)
        ensure_source_fits!(source_json)
        response = @client.chat(draft_messages(source_json), tools: [], cancellation: cancellation)
        draft(source_path: source[:path], content: MessageAccess.content(response).to_s)
      end

      def save(content, overwrite: false)
        reviewed_draft = draft(content: content)
        path = skill_path(reviewed_draft.name)
        if File.exist?(path) && !overwrite
          raise ConflictError, "A personal skill named #{reviewed_draft.name.inspect} already exists"
        end

        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        write_atomically(path, reviewed_draft.content)
        reviewed_draft
      end

      def skill_path(name)
        File.join(@config_dir, "skills", name.to_s, "SKILL.md")
      end

      private

      def ensure_source_fits!(source_json)
        context_window = @client.current_context_window
        return unless context_window

        available_tokens = context_window.to_i - OUTPUT_TOKEN_RESERVE - PROMPT_TOKEN_RESERVE
        source_tokens = @token_estimator.estimate_tokens(source_json)
        return if source_tokens <= available_tokens

        raise SourceTooLargeError,
          "Selected session needs about #{source_tokens} tokens, but only #{[available_tokens, 0].max} are available for capture"
      end

      def draft_messages(source_json)
        [
          {
            role: "system",
            content: <<~INSTRUCTIONS
              Create one reusable Kward Agent Skill from the saved session supplied by the user.
              Return only a complete SKILL.md document. Include YAML frontmatter with a lowercase
              hyphenated `name` and a concise `description`, followed by practical reusable
              instructions. Derive guidance from demonstrated workflow, commands, and conventions;
              omit credentials, private values, and project-specific incidental details. Do not
              claim the skill grants permissions or tool access.
            INSTRUCTIONS
          },
          {
            role: "user",
            content: "Saved session active branch (complete persisted records):\n\n#{source_json}"
          }
        ]
      end

      def draft(source_path: nil, content:)
        metadata, body = parse_skill(content)
        name = metadata.fetch("name", "").to_s.strip
        description = metadata.fetch("description", "").to_s.strip
        raise InvalidDraftError, "Skill frontmatter must include a name" if name.empty?
        raise InvalidDraftError, "Skill name must use lowercase letters, digits, and hyphens" unless NAME_PATTERN.match?(name)
        raise InvalidDraftError, "Skill frontmatter must include a description" if description.empty?
        raise InvalidDraftError, "Skill description exceeds 1024 characters" if description.length > 1024
        raise InvalidDraftError, "Skill instructions must not be empty" if body.strip.empty?

        Draft.new(content: normalize_content(content), source_path: source_path, name: name, description: description)
      end

      def parse_skill(content)
        match = content.to_s.match(/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/m)
        raise InvalidDraftError, "Skill must begin with YAML frontmatter" unless match

        metadata = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
        raise InvalidDraftError, "Skill frontmatter must be a mapping" unless metadata.is_a?(Hash)

        [metadata.transform_keys(&:to_s), match[2]]
      rescue Psych::SyntaxError => error
        raise InvalidDraftError, "Invalid skill frontmatter: #{error.message}"
      end

      def normalize_content(content)
        "#{content.to_s.rstrip}\n"
      end

      def write_atomically(path, content)
        Tempfile.create(["SKILL", ".tmp"], File.dirname(path)) do |file|
          file.write(content)
          file.flush
          file.fsync
          File.chmod(0o600, file.path)
          File.rename(file.path, path)
        end
        File.chmod(0o600, path)
      end
    end
  end
end
