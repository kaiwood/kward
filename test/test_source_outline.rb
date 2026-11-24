require_relative "test_helper"
require_relative "../lib/kward/source/outline"

class TestSourceOutline < KwardTestCase
  def test_fallback_recognizes_declarations_without_ctags
    with_env("PATH" => "") do
      outline = Kward::SourceOutline.new
      { "demo.rb" => "  def example\n", "demo.py" => "async def example():\n",
        "demo.ts" => "export function example() {\n", "demo.go" => "func example() {\n",
        "demo.rs" => "pub fn example() {\n" }.each do |path, source|
        assert_equal [["example", 2]], outline.symbols(path, "\n#{source}").map { |symbol| symbol.values_at(:name, :line) }
      end
    end
  end

  def test_fallback_names_omit_keywords_parameters_and_inline_class_bodies
    source = <<~SOURCE
      module Outer
        class RequestError < StandardError; end
        def self.connect(host, port: 80)
        end
      end
    SOURCE
    with_env("PATH" => "") do
      symbols = Kward::SourceOutline.new.symbols("demo.rb", source)
      assert_equal %w[Outer RequestError self.connect], symbols.map { |symbol| symbol[:name] }
      assert_equal [1, 2, 3], symbols.map { |symbol| symbol[:line] }
    end
  end

  def test_uses_json_capable_universal_ctags_on_a_private_live_snapshot
    Dir.mktmpdir do |root|
      binary = File.join(root, "ctags")
      File.write(binary, <<~RUBY_SCRIPT)
        #!#{RbConfig.ruby}
        require "json"
        abort unless ARGV.shift == "--options=NONE"
        case ARGV.first
        when "--version" then puts "Universal Ctags test"
        when "--list-features" then puts "json  JSON output"
        else
          snapshot = ARGV.last
          abort unless File.basename(snapshot) == "hello.c" && File.stat(Dir.pwd).mode & 0o777 == 0o700
          abort unless File.read(snapshot).include?("unsaved") && ENV["OUTLINE_TEST_SECRET"].nil?
          puts JSON.generate(_type: "tag", name: "unsaved", kind: "function", scope: "Demo", line: 2)
          puts JSON.generate(_type: "tag", name: "outside", kind: "function", line: 99)
        end
      RUBY_SCRIPT
      File.chmod(0o700, binary)
      path = File.join(root, "hello.c")
      File.write(path, "saved\n")
      with_env("PATH" => root, "OUTLINE_TEST_SECRET" => "private") do
        assert_equal [{ name: "unsaved", kind: "function", scope: "Demo", line: 2 }],
                     Kward::SourceOutline.new.symbols(path, "\nvoid unsaved() {}\n")
      end
      assert_equal "saved\n", File.read(path)
    end
  end
end
