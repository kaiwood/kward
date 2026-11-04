require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/native_runtime"

class TestNativeShellLocale < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def installed_multichar_locale
    %w[cs_CZ.UTF-8 cs_CZ.utf8 sk_SK.UTF-8 sk_SK.utf8].each do |name|
      begin
        supported = Kward::NativeShell::Locale.with("LC_ALL" => name) { |locale| locale.symbol?("ch", "ch") }
        return name if supported
      rescue Kward::NativeShell::ExecutionError
        next
      end
    end
    skip "install a Czech or Slovak UTF-8 locale for libc collation integration coverage"
  end

  def test_installed_collation_is_shared_by_case_parameter_trimming_and_globbing
    name = installed_multichar_locale
    Dir.mktmpdir("native-collation") do |dir|
      %w[ch chh ah x].each { |entry| File.write(File.join(dir, entry), "") }
      source = <<~'SHELL'
        case ch in [[.ch.]]) printf symbol:;; esac
        case ch in [a-z]) printf range:;; esac
        case ch in [[=ch=]]) printf equivalent:;; esac
        value=chocolate
        printf '%s:' "${value#[[.ch.]]}"
        printf '<%s>' [a[.ch.]]h
      SHELL
      output, error, status = Open3.capture3({ "LC_ALL" => name }, RbConfig.ruby, EXECUTABLE, "-c", source, chdir: dir)
      assert status.success?, error
      assert_equal "symbol:range:equivalent:ocolate:<ah><chh>", output
      assert_empty error
    end
  end

  def test_collation_names_never_turn_candidate_data_into_libc_wildcards
    Kward::NativeShell::Locale.with("LC_ALL" => installed_multichar_locale) do |locale|
      [".]]*", "[.ch", "\\*", "*a" * 100].each do |candidate|
        refute locale.symbol?(candidate, candidate)
        refute locale.equivalent?(candidate, candidate)
      end
    end
  end

  def test_category_selection_and_locale_restoration
    locale = Kward::NativeShell::Locale
    before = locale::USE.call(0).to_i
    locale.with("LC_CTYPE" => "C", "LC_COLLATE" => installed_multichar_locale) do |active|
      assert_equal Encoding::BINARY, active.encoding
      assert active.multichar
      assert active.symbol?("ch", "ch")
      locale.with("LC_ALL" => "C", "LC_COLLATE" => "invalid") do |nested|
        refute nested.multichar
        refute nested.symbol?("ch", "ch")
      end
      assert active.symbol?("ch", "ch")
    end
    assert_equal before, locale::USE.call(0).to_i
  end
end
