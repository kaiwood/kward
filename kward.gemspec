require_relative "lib/kward/version"

Gem::Specification.new do |spec|
  spec.name = "kward"
  spec.version = Kward::VERSION
  spec.authors = ["Kai Wood"]
  spec.email = ["kai.wood@icloud.com"]

  spec.summary = "A small Ruby CLI coding agent."
  spec.description = "Kward is a Ruby CLI coding agent with local workspace tools, configurable prompts, web search, sessions, and an experimental JSON-RPC backend."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |file|
      file.start_with?(".ruby-lsp/", "test/", "plan/") || [".gitignore", "AGENTS.md"].include?(file)
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
end
