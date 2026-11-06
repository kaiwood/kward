require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/script_runner"

class TestNativeShellDescriptors < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(source, **options)
    Open3.capture3({ "LC_ALL" => "C", "ENV" => nil }, RbConfig.ruby, EXECUTABLE, "-c", source, **options)
  end

  def test_inherited_input_and_duplicates_share_the_file_offset
    Tempfile.create("native-inherited-input") do |file|
      file.write("first\nsecond\n")
      file.rewind
      output, error, status = invoke("read first <&3; exec 9<&3; cat <&9; printf '%s\\n' \"$first\"", 3 => file)
      assert status.success?, error
      assert_empty error
      assert_equal "second\nfirst\n", output
      assert_equal file.size, file.pos
    end
  end

  def test_inherited_output_persists_through_exec_and_children
    Tempfile.create("native-inherited-output") do |file|
      output, error, status = invoke("printf first >&3; exec 9>&3; printf second >&9; exec /bin/echo third >&9", 3 => file)
      assert status.success?, error
      assert_empty error
      assert_empty output
      file.rewind
      assert_equal "firstsecondthird\n", file.read
    end
  end

  def test_inherited_descriptors_reach_native_script_and_executable_text
    Dir.mktmpdir("native-inherited-fallback") do |dir|
      File.write(File.join(dir, "script"), "cat <&3; printf done >&9\n")
      File.chmod(0o700, File.join(dir, "script"))
      ["kwsh script", "./script", "exec ./script"].each do |command|
        Tempfile.create("native-inherited-data") do |input|
          Tempfile.create("native-inherited-result") do |result|
            input.write("payload\n")
            input.rewind
            output, error, status = invoke(command, 3 => input, 9 => result, chdir: dir)
            assert status.success?, error
            assert_empty error
            assert_equal "payload\n", output
            result.rewind
            assert_equal "done", result.read
          end
        end
      end
    end
  end

  def test_closed_inherited_descriptor_does_not_reach_external_children
    Tempfile.create("native-inherited-close") do |file|
      probe = Shellwords.join([RbConfig.ruby, "-e", 'begin; IO.for_fd(9); exit 1; rescue Errno::EBADF, ArgumentError; exit 0; end'])
      output, error, status = invoke("exec 9>&-; #{probe}", 9 => file)
      assert status.success?, error
      assert_empty error
      assert_empty output
      _, error, status = invoke("exec 9>&-; : >&9", 9 => file)
      refute status.success?
      assert_includes error, "bad file descriptor: 9"
      refute file.closed?
    end
  end

  def test_every_supported_inherited_descriptor_is_available
    (3..9).each do |descriptor|
      Tempfile.create("native-inherited-range") do |file|
        file.write("#{descriptor}\n")
        file.rewind
        output, error, status = invoke("cat <&#{descriptor}", descriptor => file)
        assert status.success?, error
        assert_equal "#{descriptor}\n", output
      end
    end
  end

  def test_owned_descriptors_close_when_removed_and_on_runner_failure
    Tempfile.create("native-owned-descriptor") do |file|
      runtime = Kward::NativeShell::Runtime.new(descriptors: { 3 => file }, own_descriptors: true)
      assert_equal 0, runtime.run("exec 3>&-")
      assert file.closed?
    ensure
      runtime&.close
    end
    [["-c"], ["/missing/native-script"], ["-c", ":"]].each do |arguments|
      Tempfile.create("native-runner-owned") do |file|
        Kward::NativeShell::ScriptRunner.run(arguments, descriptors: { 3 => file }, own_descriptors: true,
                                            input: StringIO.new, output: StringIO.new, error: StringIO.new)
        assert file.closed?
      end
    end
  end

  def test_private_close_on_exec_descriptor_is_not_discovered
    Tempfile.create("native-private-cloexec") do |file|
      bootstrap = <<~RUBY
        require #{File.expand_path("../lib/kward/shell/script_runner", __dir__).inspect}
        io = IO.for_fd(9)
        io.close_on_exec = true
        descriptors = Kward::NativeShell::NativeProcess.inherited_descriptors
        abort "private descriptor exposed" if descriptors.key?(9)
        abort "private descriptor closed" if io.closed?
      RUBY
      _, error, status = Open3.capture3(RbConfig.ruby, "-e", bootstrap, 9 => file)
      assert status.success?, error
      assert_empty error
    end
  end

  def test_runtime_never_discovers_host_descriptors_implicitly
    Tempfile.create("native-private") do |file|
      file.close_on_exec = false
      runtime = Kward::NativeShell::Runtime.new
      error = StringIO.new
      assert_equal 2, runtime.run(": >&9", output: StringIO.new, error: error)
      assert_includes error.string, "bad file descriptor: 9"
      refute file.closed?
    ensure
      runtime&.close
    end
  end
end
