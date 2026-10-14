require_relative "server"

Kward.plugin(id: "com.kward.openrouter-proxy", version: "1.0.0", api: 1) do |plugin|
  plugin.startup_option("--openrouter-proxy", description: "Run the local Codex-backed OpenRouter proxy") do |host|
    Kward::OpenRouterProxy::Server.new(host: host).run
  end
end
