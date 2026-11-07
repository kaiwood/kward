require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/native_runtime"

class TestNativeShellLimits < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)
  Arithmetic = Kward::NativeShell::Arithmetic

  def test_long_nonoverflowing_arithmetic_runs_standalone_and_hosted
    expression = "1" + " + 0" * 2_000
    source = "printf '%s' \"$((#{expression}))\""
    output, error, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "-c", source)
    assert status.success?, error
    assert_empty error
    assert_equal "1", output
    runtime = Kward::NativeShell::Runtime.new(interactive: true, hosted: true)
    output, error = StringIO.new, StringIO.new
    assert_equal 0, runtime.run("answer=$((#{expression}))", output: output, error: error)
    assert_empty error.string
    assert_equal "1", runtime.variables.fetch("answer")
  ensure
    runtime&.close
  end

  def test_long_binary_chains_preserve_order_and_lazy_side_effects
    values = { "i" => "0" }
    assign = ->(name, value) { values[name] = value }
    expression = "0" + " || (i += 1)" * 1_000
    assert_equal 1, Arithmetic.evaluate(expression, assign: assign) { |name| values.fetch(name, "0") }
    assert_equal "1", values.fetch("i")
    assert_equal(-1_000, Arithmetic.evaluate("0" + " - 1" * 1_000) { "0" })
    assert_equal 0, Arithmetic.evaluate("1" + " && 0" * 1_000 + " && (1 / 0)") { "0" }
    assert_equal 17, Arithmetic.evaluate("20 - 2 - 3 + 5 * 2 / 5") { "0" }
  end

  def test_long_integer_spellings_are_bounded_by_value_not_leading_zeros
    assert_equal 1, Arithmetic.integer("0" * 5_000 + "1")
    assert_equal(-15, Arithmetic.integer("-0x" + "0" * 5_000 + "f"))
    assert_equal 0, Arithmetic.integer("0" * 10_000)
    error = assert_raises(Arithmetic::Error) { Arithmetic.integer("9" * 10_000) }
    assert_includes error.message, "exceeds"
  end

  def test_long_syntax_validation_does_not_evaluate_variables_or_substitutions
    expression = "missing" + " + 0" * 2_000
    Arithmetic::Parser.new(expression).parse
    Dir.mktmpdir("native-limit-validation") do |dir|
      source = "printf '%s' \"$((#{expression} + $(touch sentinel; printf 1)))\""
      output, error, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "-nc", source, chdir: dir)
      assert status.success?, error
      assert_empty output
      assert_empty error
      refute File.exist?(File.join(dir, "sentinel"))
    end
  end
end
