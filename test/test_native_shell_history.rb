require_relative "test_helper"
require "open3"
require "tmpdir"
require_relative "../lib/kward/shell/script_runner"

class TestNativeShellHistory < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(source, env: {}, **options)
    Open3.capture3({ "ENV" => nil, "HISTFILE" => "", "PS1" => "", "PS2" => "", "LC_ALL" => "C" }.merge(env),
                   RbConfig.ruby, EXECUTABLE, "-i", stdin_data: source, **options)
  end

  def test_listing_ranges_numbers_and_multiline_commands
    out, err, status = invoke("a=one\nb=two\nif true; then\nc=three\nfi\nfc -l\nfc -lnr 1 2\nexit\n")
    assert status.success?, err
    assert_equal "1\ta=one\n2\tb=two\n3\tif true; then\n\tc=three\n\tfi\n\tb=two\n\ta=one\n", out
  end

  def test_substitution_reexecution_assignments_and_redirects
    Dir.mktmpdir do |dir|
      out, err, status = invoke("printf '%s:%s\\n' old \"$VALUE\"\nVALUE=ok fc -s old=new >result\ncat result\nfc -l\nexit\n", chdir: dir)
      assert status.success?, err
      assert_includes out, "new:ok\n"
      assert_includes out, "2\tprintf '%s:%s\\n' new \"$VALUE\"\n"
      refute_includes out, "2\tVALUE=ok fc"
    end
  end

  def test_editor_success_failure_private_files_and_cleanup
    Dir.mktmpdir do |dir|
      editor = File.join(dir, "editor")
      File.write(editor, "#!/usr/bin/env ruby\np = ARGV.fetch(0)\nFile.write(#{File.join(dir, 'path').inspect}, p)\nabort 'not private' unless File.stat(p).mode & 0777 == 0600\nFile.write(p, \"printf 'edited\\\\n'\\n\")\nexit ENV.fetch('FAIL', '0').to_i\n")
      File.chmod(0700, editor)
      out, err, status = invoke("true\nfc\nFAIL=7 fc\nprintf 'status:%s\\n' \"$?\"\nfc -l\nexit\n", env: { "FCEDIT" => editor })
      assert status.success?, err
      assert_equal 1, out.lines.count { |line| line == "edited\n" }
      assert_includes out, "status:7\n"
      refute File.exist?(File.read(File.join(dir, "path")))
      refute_includes out, "\tFAIL=7 fc"
    end
  end

  def test_editor_cancellation_cleans_up_and_does_not_replay
    runtime = Kward::NativeShell::Runtime.new(hosted: false, interactive: true, env: { "HISTFILE" => "" })
    runtime.history.add("value=unsafe")
    path = nil
    editor = ->(arguments, _streams) { path = arguments.last; raise Interrupt }
    runtime.define_singleton_method(:external, &editor)
    runtime.with_history_entry("fc") { runtime.run("fc", output: StringIO.new, error: StringIO.new) }
    assert_equal 130, runtime.status
    assert_nil runtime.variables["value"]
    assert_equal [[1, "value=unsafe"]], runtime.history.entries
    refute File.exist?(path)
    refute Dir.exist?(File.dirname(path))
  ensure
    runtime&.send(:close_resources)
  end

  def test_missing_entries_options_and_prefixes
    out, err, status = invoke("a=first\nb=second\nfc -s a=changed a=\nfc -s -- -99\nprintf 'status:%s\\n' \"$?\"\nfc -ln 1 999\nexit\n")
    assert status.success?, err
    assert_includes out, "status:2\n"
    assert_includes err, "history entry not found"
    assert_includes out, "\tchanged=first\n"
  end

  def test_persistence_round_trips_non_utf8_command_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history")
      out, error, status = invoke("# \xff\nfc -l\nexit\n".b, env: { "HISTFILE" => path, "LC_ALL" => "C" })
      assert status.success?, error
      assert_includes out.b, "1\t# \xff\n".b
      out, error, status = invoke("fc -ln 1 1\nexit\n", env: { "HISTFILE" => path, "LC_ALL" => "C" })
      assert status.success?, error
      assert_equal "\t# \xff\n".b, out.b
    end
  end

  def test_file_size_limit_falls_back_to_memory_without_overwriting_history
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history")
      original = "[1,\"true\"]\n"
      File.write(path, original, perm: 0600)
      out, error, status = invoke("ulimit -S -f 0\na=recorded\nfc -l\nexit\n", env: { "HISTFILE" => path })
      assert status.success?, "#{status}: #{error}"
      assert_empty error
      assert_equal "1\ttrue\n2\tulimit -S -f 0\n3\ta=recorded\n", out
      assert_equal original, File.read(path)
      assert_equal ["history", "history.lock"], Dir.children(dir).sort
    end
  end

  def test_forked_history_cannot_overwrite_parent_storage
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history")
      runtime = Kward::NativeShell::Runtime.new(env: { "HISTFILE" => path }, hosted: false)
      runtime.history.add("parent=one")
      before = File.read(path)
      pid = fork { runtime.history.add("child=private"); exit! 0 }
      Process.waitpid(pid)
      assert_equal before, File.read(path)
      runtime.history.add("parent=two")
      assert_equal [1, 2], runtime.history.entries.map(&:first)
      refute_includes File.read(path), "child"
    ensure
      runtime&.send(:close_resources)
    end
  end

  def test_editor_setting_is_not_shell_source
    Dir.mktmpdir do |dir|
      _, error, = invoke("true\nfc\nexit\n", env: { "FCEDIT" => '$(touch injected)' }, chdir: dir)
      assert_includes error, "only parameter expansion"
      refute File.exist?(File.join(dir, "injected"))
    end
  end

  def test_persistence_size_and_unsafe_history_fallback
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history")
      env = { "HISTFILE" => path, "HISTSIZE" => "2" }
      invoke("a=1\nb=2\nc=3\n", env: env)
      out, err, status = invoke("fc -l\n", env: env)
      assert status.success?, err
      assert_equal "2\tb=2\n3\tc=3\n", out
      assert_equal 0600, File.stat(path).mode & 0777
      File.chmod(0644, path)
      before = File.read(path)
      out, = invoke("safe=yes\nfc -l\n", env: env)
      assert_equal "1\tsafe=yes\n", out
      assert_equal before, File.read(path)
      File.symlink(path, File.join(dir, "link"))
      invoke("private=yes\n", env: env.merge("HISTFILE" => File.join(dir, "link")))
      assert_equal before, File.read(path)
    end
  end
end
