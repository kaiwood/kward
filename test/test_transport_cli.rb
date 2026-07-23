require_relative "test_helper"

class TestTransportCLI < KwardTestCase
  def test_transport_list_reports_plugin_transport
    Dir.mktmpdir do |home|
      plugins = File.join(home, ".kward", "plugins")
      FileUtils.mkdir_p(plugins)
      File.write(File.join(plugins, "demo.rb"), <<~RUBY)
        Kward.plugin do |plugin|
          plugin.transport "demo", id: "com.example.demo", capabilities: { inbound: [:text] } do
            Class.new do
              def start; end
              def stop; end
            end.new
          end
        end
      RUBY

      prompt = FakePrompt.new([])
      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        Kward::CLI.new(argv: ["transport", "list"], prompt: prompt, client: FakeClient.new([])).run
      end

      assert_equal ["com.example.demo\tstopped"], prompt.output
    end
  end
end
