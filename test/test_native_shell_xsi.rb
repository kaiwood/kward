require_relative "test_helper"
require "open3"

class TestNativeShellXsi < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(source, **options)
    Open3.capture3({ "LC_ALL" => "C", "ENV" => nil }, RbConfig.ruby, EXECUTABLE, "-c", source, **options)
  end

  def test_type_describes_current_aliases_functions_keywords_builtins_and_paths
    Dir.mktmpdir("native-xsi-type") do |dir|
      File.write(File.join(dir, "custom"), "exit 0\n")
      File.chmod(0o700, File.join(dir, "custom"))
      output, error, status = invoke(<<~'SHELL', chdir: dir)
        PATH=.
        alias shortcut='custom argument'
        work() { :; }
        hash custom
        type shortcut work if ulimit custom ./custom missing_native_xsi
      SHELL
      refute status.success?
      assert_empty error
      assert_includes output, "alias shortcut="
      assert_includes output, "work is function\n"
      assert_includes output, "if is keyword\n"
      assert_includes output, "ulimit is shell builtin\n"
      assert_includes output, "custom is #{File.realpath(dir)}/custom\n"
      assert_includes output, "./custom is #{File.realpath(dir)}/custom\n"
      refute_includes output, "missing_native_xsi"
    end
  end

  def test_type_requires_an_operand_without_aborting_the_script
    output, error, status = invoke("type; result=$?; printf alive; exit $result")
    refute status.success?
    assert_equal "alive", output
    assert_includes error, "type:"
  end

  def test_xsi_numeric_trap_mapping_listing_and_reset
    output, error, status = invoke(<<~'SHELL')
      trap ':' 1 2 3 6 14 15
      trap -p 1 2 3 6 14 15
      trap - 9
      trap 1 2 3 6 14 15
      trap -p 1 2 3 6 9 14 15
    SHELL
    assert status.success?, error
    assert_empty error
    lines = output.lines.map(&:chomp)
    %w[HUP INT QUIT ABRT ALRM TERM].each_with_index do |name, index|
      assert_equal "trap -- : #{name}", lines[index]
    end
    assert_equal %w[HUP INT QUIT ABRT KILL ALRM TERM].map { |name| "trap -- - #{name}" }, lines.drop(6)
  end

  def test_xsi_kill_numeric_and_case_independent_symbolic_forms
    { 1 => "HUP", 2 => "INT", 3 => "QUIT", 6 => "ABRT", 14 => "ALRM", 15 => "TERM" }.each do |number, name|
      ["-#{number}", "-#{name}", "-#{name.downcase}", "-s #{name.downcase}"].each do |option|
        output, error, status = invoke("ulimit -c 0; trap 'printf caught' #{name}; kill #{option} $$; :")
        assert status.success?, "#{option}: #{error}"
        assert_empty error
        assert_equal "caught", output, option
      end
    end
    output, error, status = invoke("kill -0 $$; printf '%s' \"$?\"")
    assert status.success?, error
    assert_empty error
    assert_equal "0", output
    _, error, status = invoke("kill -9 $$")
    assert_empty error
    assert status.signaled?
    assert_equal Signal.list.fetch("KILL"), status.termsig
  end

  def test_invalid_numeric_trap_is_diagnostic_and_nonfatal
    output, error, status = invoke("trap ':' 999999; result=$?; printf alive; exit $result")
    refute status.success?
    assert_equal "alive", output
    assert_includes error, "invalid signal: 999999"
  end
end
