require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/native_runtime"

class TestNativeShellUtilities < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(source, **options)
    Open3.capture3({ "LC_ALL" => "C", "ENV" => nil }, RbConfig.ruby, EXECUTABLE, "-c", source, **options)
  end

  def test_umask_permission_copy_and_sequential_symbolic_actions
    cases = {
      "077; umask g=u" => "0007",
      "027; umask o=g" => "0022",
      "027; umask uo=g" => "0222",
      "000; umask g=u-w" => "0020",
      "000; umask a+=rwx-w" => "0222",
      "777; umask u=rwx,g=u,o=g-w" => "0002",
      "022; umask a+" => "0022",
      "022; umask a=" => "0777",
      "077; umask a+X" => "0066",
      "111; umask a+X" => "0111",
      "022; umask a+st" => "0022",
      "000000022; umask -- -w" => "0222"
    }
    cases.each do |commands, expected|
      output, error, status = invoke("umask #{commands}; umask")
      assert status.success?, error
      assert_equal "#{expected}\n", output, commands
      assert_empty error
    end
  end

  def test_umask_options_round_trips_and_subshell_file_effects
    Dir.mktmpdir("native-mask") do |dir|
      output, error, status = invoke(<<~'SHELL', chdir: dir)
        umask -- 027
        saved=$(umask -S)
        umask -S 077
        : >private
        (umask -- 002; : >shared)
        umask "$saved"
        : >restored
        umask -S --
        umask
      SHELL
      assert status.success?, error
      assert_empty error
      assert_equal "u=rwx,g=rx,o=\n0027\n", output
      assert_equal 0o600, File.stat(File.join(dir, "private")).mode & 0o777
      assert_equal 0o664, File.stat(File.join(dir, "shared")).mode & 0o777
      assert_equal 0o640, File.stat(File.join(dir, "restored")).mode & 0o777
    end
  end

  def test_invalid_symbolic_umask_does_not_partially_change_the_mask
    %w[u=rw,g=ur u=rw, u=rw,garbage u=rw,go z=r 888].each do |mask|
      output, error, status = invoke("umask 022; umask #{Shellwords.escape(mask)}; result=$?; umask; exit $result")
      refute status.success?, mask
      assert_equal "0022\n", output
      assert_includes error, "umask:"
    end
  end

  def test_cd_physical_e_and_last_logical_or_physical_option_win
    Dir.mktmpdir("native-cd") do |dir|
      Dir.mkdir(File.join(dir, "real"))
      Dir.mkdir(File.join(dir, "real", "child"))
      File.symlink("real/child", File.join(dir, "link"))
      { "-Pe" => "real", "-eP" => "real", "-PLe" => "", "-LPe" => "real" }.each do |flags, suffix|
        output, error, status = invoke("cd #{flags} link/..; pwd -P", chdir: dir)
        assert status.success?, error
        assert_empty error
        assert_equal "#{File.join(File.realpath(dir), suffix).delete_suffix('/')}\n", output
      end
    end
  end

  def test_cd_e_reports_path_failure_after_successful_directory_change
    Dir.mktmpdir("native-cd-report") do |dir|
      target = File.join(File.realpath(dir), "target")
      Dir.mkdir(target)
      original = File.method(:realpath)
      %w[-Pe -P].each do |flags|
        runtime = Kward::NativeShell::Runtime.new(cwd: dir, env: {})
        output, error = StringIO.new, StringIO.new
        begin
          # Simulate getcwd/path reporting denial, not a failed directory change.
          File.define_singleton_method(:realpath) do |path, *args|
            raise Errno::EACCES, path if path == target
            original.call(path, *args)
          end
          status = runtime.run("cd #{flags} ./target", output: output, error: error)
          assert_equal(flags == "-Pe" ? 1 : 0, status)
          assert File.identical?(target, runtime.cwd)
          assert_empty output.string
          refute_equal 0, runtime.run("pwd -L", output: output, error: error)
          assert_empty output.string
          assert_equal 0, runtime.run(": >proof", output: output, error: error)
          assert File.file?(File.join(target, "proof"))
        ensure
          File.define_singleton_method(:realpath, original)
          runtime.close
        end
      end
    end
  end
end
