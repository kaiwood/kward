require_relative "lib/kward/version"

Gem::Specification.new do |spec|
  spec.name = "kward"
  spec.version = Kward::VERSION
  spec.authors = ["Kai Wood"]
  spec.email = ["kai.wood@icloud.com"]

  spec.summary = "An extensible Ruby coding agent for your terminal."
  spec.description = "Kward is an extensible Ruby coding agent with workspace tools, resumable sessions, multiple model providers, a local browser UI, and JSON-RPC integrations."
  spec.homepage = "https://kaiwood.github.io/kward/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/kaiwood/kward"
  spec.metadata["changelog_uri"] = "https://github.com/kaiwood/kward/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://kaiwood.github.io/kward/"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kaiwood/kward/issues"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |file|
      file.start_with?(".github/", ".ruby-lsp/", "script/", "test/", "plan/") || [".gitignore", "AGENTS.md"].include?(file)
    end
  end
  spec.bindir = "exe"
  spec.executables = ["kward"]
  spec.require_paths = ["lib"]

  spec.add_dependency "base64"
  spec.add_dependency "nokogiri"
  spec.add_dependency "tiktoken_ruby"
  spec.add_dependency "tty-cursor"
  spec.add_dependency "tty-prompt"
  spec.add_dependency "tty-reader"
  spec.add_dependency "tty-screen"
  spec.add_dependency "unicode-display_width"
end
