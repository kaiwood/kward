require_relative "test_helper"
require_relative "../lib/kward/shell/native_pattern"

class TestNativeShellPattern < KwardTestCase
  def test_shell_wildcards_match_whole_strings_including_slashes_dots_and_newlines
    {
      "*" => ["", ".hidden/path", "a\nb"],
      "a?c" => ["abc", "a\nc"],
      "*ab*c" => ["ababc", "aabc"],
      "" => [""],
      'a.(b)+' => ['a.(b)+'],
      '\\*' => ['*']
    }.each do |pattern, values|
      matcher = Kward::NativeShell::Pattern.new(pattern)
      values.each { |value| assert matcher.match?(value), [pattern, value].inspect }
    end
    refute Kward::NativeShell::Pattern.new("a?c").match?("ac")
    refute Kward::NativeShell::Pattern.new("a").match?("ab")
    refute Kward::NativeShell::Pattern.new("").match?("a")
  end

  def test_bracket_classes_ranges_negation_and_escaped_characters
    {
      '[[:digit:]]' => ["3"],
      '[![:digit:]]' => ["a", "\n"],
      '[[:alpha:][:digit:]]' => ["a", "3"],
      '[a-c]' => ["a", "b", "c"],
      '[a\\-c]' => ["a", "-", "c"],
      '[]a]' => ["]", "a"],
      '[a&&b]' => ["a", "&", "b"],
      '[' => ["["],
      '[abc' => ["[abc"]
    }.each do |pattern, values|
      matcher = Kward::NativeShell::Pattern.new(pattern)
      values.each { |value| assert matcher.match?(value), [pattern, value].inspect }
    end
    refute Kward::NativeShell::Pattern.new('[a\\-c]').match?("b")
    refute Kward::NativeShell::Pattern.new('[!a]').match?("a")
    refute Kward::NativeShell::Pattern.new('[[:digit:]]').match?("x")
    refute Kward::NativeShell::Pattern.new('[z-a]').match?("z")
  end

  def test_quoted_and_incomplete_patterns_do_not_require_directory_scans
    refute Kward::NativeShell::Pattern.new('\*').wildcards?
    refute Kward::NativeShell::Pattern.new('\[quoted\]').wildcards?
    refute Kward::NativeShell::Pattern.new('[incomplete').wildcards?
    assert Kward::NativeShell::Pattern.new('[a-c]').wildcards?
    assert Kward::NativeShell::Pattern.new('*').wildcards?
  end

  def test_many_wildcards_do_not_use_recursive_or_regex_backtracking
    pattern = Kward::NativeShell::Pattern.new("*a" * 200 + "z")
    refute pattern.match?("a" * 400)
    assert pattern.match?("a" * 400 + "z")
  end
end
