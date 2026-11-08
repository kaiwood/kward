require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/native_runtime"

class TestNativeShellDirectory < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(source, **options)
    Open3.capture3({ "LC_ALL" => "C", "ENV" => nil }, RbConfig.ruby, EXECUTABLE, "-c", source, **options)
  end

  def test_logical_cd_checks_components_before_removing_dot_dot
    Dir.mktmpdir("native-cd-components") do |dir|
      Dir.mkdir(File.join(dir, "real"))
      File.write(File.join(dir, "file"), "data")
      File.symlink("real", File.join(dir, "link"))
      File.symlink("missing", File.join(dir, "dangling"))
      %w[missing/.. file/.. dangling/.. real/missing/../..].each do |path|
        output, error, status = invoke("cd #{path}; result=$?; pwd -P; exit $result", chdir: dir)
        refute status.success?, path
        refute_empty error
        assert_equal "#{File.realpath(dir)}\n", output
      end
      output, error, status = invoke("cd link/..; pwd -P", chdir: dir)
      assert status.success?, error
      assert_empty error
      assert_equal "#{File.realpath(dir)}\n", output
    end
  end

  def test_renamed_directory_is_retained_across_commands_sources_globs_and_subshells
    Dir.mktmpdir("native-cwd-rename") do |dir|
      Dir.mkdir(File.join(dir, "old"))
      File.write(File.join(dir, "old", "library"), "SOURCE=loaded\n")
      File.write(File.join(dir, "old", "script"), "printf 'script:%s\\n' \"$SOURCE\"\n")
      output, error, status = invoke(<<~'SHELL', chdir: dir)
        cd old
        mv ../old ../new
        mkdir ../old
        printf data >note.txt
        . ./library
        export SOURCE
        kwsh script
        (printf '%s\n' *.txt; pwd -P)
        printf 'logical:%s\n' "${PWD##*/}"
        printf '%s:%s\n' "$SOURCE" "$(cat note.txt)"
        pwd -P
        cd ..
        pwd -P
      SHELL
      assert status.success?, error
      assert_empty error
      physical = File.realpath(dir)
      assert_equal "script:loaded\nnote.txt\n#{physical}/new\nlogical:old\nloaded:data\n#{physical}/new\n#{physical}\n", output
      assert_equal "data", File.read(File.join(dir, "new", "note.txt"))
      refute File.exist?(File.join(dir, "old", "note.txt"))
    end
  end

  def test_dot_search_skips_unreadable_path_candidates
    Dir.mktmpdir("native-dot-path") do |dir|
      first = File.join(dir, "first")
      second = File.join(dir, "second")
      Dir.mkdir(first)
      Dir.mkdir(second)
      blocked = File.join(first, "library")
      File.write(blocked, "VALUE=wrong\n")
      File.chmod(0, blocked)
      File.write(File.join(second, "library"), "VALUE=loaded\n")

      output, error, status = invoke("PATH=first:second:/usr/bin:/bin; . library; printf '%s' \"$VALUE\"", chdir: dir)

      assert status.success?, error
      assert_empty error
      assert_equal "loaded", output
    ensure
      File.chmod(0o600, blocked) if blocked && File.exist?(blocked)
    end
  end

  def test_relative_lookup_and_exec_use_the_renamed_directory
    Dir.mktmpdir("native-cwd-exec") do |dir|
      Dir.mkdir(File.join(dir, "old"))
      file = File.join(dir, "old", "tool")
      File.write(file, "printf '%s:' \"$0\"; cat input\n")
      File.chmod(0o700, file)
      File.write(File.join(dir, "old", "input"), "payload")
      output, error, status = invoke(<<~'SHELL', chdir: dir)
        cd old
        PATH=.:$PATH
        hash tool
        mv ../old ../new
        mkdir ../old
        printf 'printf wrong' >../old/tool
        chmod +x ../old/tool
        tool
        exec ./tool
      SHELL
      assert status.success?, error
      assert_empty error
      assert_equal "tool:payload./tool:payload", output
    end
  end

  def test_relative_redirection_does_not_lexically_remove_symlink_dot_dot
    Dir.mktmpdir("native-cwd-redirection") do |dir|
      Dir.mkdir(File.join(dir, "real"))
      Dir.mkdir(File.join(dir, "real", "child"))
      File.symlink("real/child", File.join(dir, "link"))
      output, error, status = invoke("printf data >link/../result; cat link/../result", chdir: dir)
      assert status.success?, error
      assert_empty error
      assert_equal "data", output
      assert File.file?(File.join(dir, "real", "result"))
      refute File.exist?(File.join(dir, "result"))
    end
  end

  def test_removed_directory_allows_external_execution_and_physical_parent_navigation
    Dir.mktmpdir("native-cwd-removed") do |dir|
      Dir.mkdir(File.join(dir, "gone"))
      File.write(File.join(dir, "parent.txt"), "parent")
      output, error, status = invoke(<<~'SHELL', chdir: dir)
        cd gone
        rmdir ../gone
        /usr/bin/printf 'alive\n'
        pwd -P
        printf 'pwd-status:%s\n' "$?"
        printf 'glob:%s\n' ../*.txt
        printf 'empty:%s\n' *
        cd -P ..
        pwd -P
      SHELL
      assert status.success?, error
      assert_match(/\Aalive\npwd-status:[1-9][0-9]*\n/, output)
      assert output.end_with?("glob:../parent.txt\nempty:*\n#{File.realpath(dir)}\n")
      refute_empty error
    end
  end

  def test_directory_handles_close_on_change_failure_and_shutdown
    Dir.mktmpdir("native-directory-owner") do |dir|
      Dir.mkdir(File.join(dir, "child"))
      runtime = Kward::NativeShell::Runtime.new(cwd: dir, env: {})
      original = runtime.instance_variable_get(:@directory)
      output, error = StringIO.new, StringIO.new
      begin
        assert IO.for_fd(original.fileno, autoclose: false).close_on_exec?
        refute_equal 0, runtime.run("cd missing", output: output, error: error)
        refute original.closed?
        assert_equal 0, runtime.run("cd child", output: output, error: error)
        assert original.closed?
        current = runtime.instance_variable_get(:@directory)
        copy = current.dup
        begin
          refute_equal current.fileno, copy.fileno
          assert IO.for_fd(copy.fileno, autoclose: false).close_on_exec?
          assert_raises(ArgumentError) { copy.open_file("bad\0name", "w") }
          current.open_file("note", "w") { |file| file.write("kept") }
          assert_equal "kept", copy.open_file("note", &:read)
        ensure
          copy.close
        end
        runtime.close
        assert current.closed?
        assert copy.closed?
      ensure
        runtime.close
      end
    end
  end

  def test_search_only_directories_do_not_require_read_permission
    Dir.mktmpdir("native-directory-permissions") do |dir|
      target = File.join(dir, "target")
      Dir.mkdir(target)
      File.write(File.join(target, "library"), "value=read\n")
      begin
        File.chmod(0o111, target)
        skip "filesystem or privileges do not enforce directory read permissions" if File.readable?(target)
        output, error, status = invoke("cd target; . ./library; printf '%s' \"$value\"; cd ..", chdir: dir)
        assert status.success?, error
        assert_empty error
        assert_equal "read", output
      ensure
        File.chmod(0o700, target)
      end
    end
  end

  def test_failed_exec_redirection_cannot_overwrite_the_owned_directory_handle
    Dir.mktmpdir("native-directory-remap") do |dir|
      code = <<~'RUBY'
        require "kward/shell/native_directory"
        require "kward/shell/native_process"
        directory = Kward::NativeShell::Directory.new(ARGV[0])
        File.open(File.join(ARGV[0], "redirected"), "w") do |file|
          streams = { 0 => STDIN, 1 => STDOUT, 2 => STDERR, directory.fileno => file }
          status = Kward::NativeShell::NativeProcess.replace("/missing-kwsh-program", ["missing"], ENV.to_h, cwd: directory, streams: streams)
          puts status
          puts directory.physical_path
        end
        directory.close
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", code, dir)
      assert status.success?, error
      assert_equal "127\n#{File.realpath(dir)}\n", output
      assert_includes error, "missing-kwsh-program"
    end
  end

  def test_private_directory_handle_is_not_inherited_by_external_commands
    Dir.mktmpdir("native-directory-exec") do |dir|
      code = <<~'RUBY'
        directory = File.stat(Dir.pwd)
        leaked = (3..64).any? do |fd|
          stat = IO.for_fd(fd, autoclose: false).stat
          stat.directory? && stat.dev == directory.dev && stat.ino == directory.ino
        rescue SystemCallError, IOError, ArgumentError
          false
        end
        print leaked
      RUBY
      output, error, status = invoke("#{Shellwords.escape(RbConfig.ruby)} -e #{Shellwords.escape(code)}", chdir: dir)
      assert status.success?, error
      assert_empty error
      assert_equal "false", output
    end
  end

  def test_hosted_runtime_retains_identity_without_changing_the_host_cwd
    Dir.mktmpdir("native-host-cwd") do |dir|
      old = File.join(dir, "old")
      renamed = File.join(dir, "new")
      Dir.mkdir(old)
      runtime = Kward::NativeShell::Runtime.new(cwd: old, env: {}, hosted: true)
      host = Dir.pwd
      begin
        File.rename(old, renamed)
        Dir.mkdir(old)
        output, error = StringIO.new, StringIO.new
        assert_equal 0, runtime.run("value=retained; : >proof; pwd -P", output: output, error: error)
        assert_equal "#{File.realpath(renamed)}\n", output.string
        assert_empty error.string
        assert File.file?(File.join(renamed, "proof"))
        refute File.exist?(File.join(old, "proof"))
        assert_equal host, Dir.pwd
      ensure
        runtime.close
      end
    end
  end
end
