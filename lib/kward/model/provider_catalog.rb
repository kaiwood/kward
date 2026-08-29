# Namespace for Kward model-provider definitions.
module Kward
  # Stable, frontend-neutral descriptions of providers Kward can present to users.
  # Runtime request and authentication mechanics remain in their respective clients.
  module ProviderCatalog
    Definition = Struct.new(
      :id,
      :name,
      :api_key_env,
      :protocol,
      :oauth_name,
      :requires_setup,
      keyword_init: true
    ) do
      def api_key?
        !api_key_env.empty?
      end

      def oauth?
        !oauth_name.nil?
      end
    end

    Runtime = Struct.new(:id, :model_config_key, :reasoning_config_key, :chat_url, :model_list_url, :model_discovery, keyword_init: true) do
      def automatic_model_discovery?
        model_discovery == :live
      end
    end

    CHAT_URLS = {
      "anthropic" => "https://api.anthropic.com/v1/messages",
      "cerebras" => "https://api.cerebras.ai/v1/chat/completions",
      "deepseek" => "https://api.deepseek.com/chat/completions",
      "fireworks" => "https://api.fireworks.ai/inference/v1/chat/completions",
      "gemini" => "https://generativelanguage.googleapis.com/v1beta",
      "groq" => "https://api.groq.com/openai/v1/chat/completions",
      "mistral" => "https://api.mistral.ai/v1/chat/completions",
      "nvidia" => "https://integrate.api.nvidia.com/v1/chat/completions",
      "openai" => "https://api.openai.com/v1/responses",
      "openrouter" => "https://openrouter.ai/api/v1/chat/completions",
      "together" => "https://api.together.xyz/v1/chat/completions",
      "xai" => "https://api.x.ai/v1/chat/completions"
    }.freeze
    MODEL_LIST_URLS = {
      "anthropic" => "https://api.anthropic.com/v1/models",
      "cerebras" => "https://api.cerebras.ai/v1/models",
      "deepseek" => "https://api.deepseek.com/models",
      "fireworks" => "https://api.fireworks.ai/inference/v1/models",
      "gemini" => "https://generativelanguage.googleapis.com/v1beta/models",
      "groq" => "https://api.groq.com/openai/v1/models",
      "mistral" => "https://api.mistral.ai/v1/models",
      "nvidia" => "https://integrate.api.nvidia.com/v1/models",
      "openai" => "https://api.openai.com/v1/models",
      "together" => "https://api.together.xyz/v1/models",
      "xai" => "https://api.x.ai/v1/models"
    }.freeze

    DEFINITIONS = [
      Definition.new(id: "anthropic", name: "Anthropic", api_key_env: ["ANTHROPIC_API_KEY"], protocol: "anthropic_messages", oauth_name: "Anthropic Claude"),
      Definition.new(id: "azure_openai", name: "Azure OpenAI", api_key_env: ["AZURE_OPENAI_API_KEY"], protocol: "azure_openai", requires_setup: true),
      Definition.new(id: "cerebras", name: "Cerebras", api_key_env: ["CEREBRAS_API_KEY"], protocol: "openai_chat"),
      Definition.new(id: "deepseek", name: "DeepSeek", api_key_env: ["DEEPSEEK_API_KEY"], protocol: "openai_chat"),
      Definition.new(id: "fireworks", name: "Fireworks AI", api_key_env: ["FIREWORKS_API_KEY"], protocol: "openai_chat"),
      Definition.new(id: "gemini", name: "Google Gemini", api_key_env: ["GEMINI_API_KEY"], protocol: "gemini"),
      Definition.new(id: "groq", name: "Groq", api_key_env: ["GROQ_API_KEY"], protocol: "openai_chat"),
      Definition.new(id: "mistral", name: "Mistral", api_key_env: ["MISTRAL_API_KEY"], protocol: "openai_chat"),
      Definition.new(id: "nvidia", name: "NVIDIA NIM", api_key_env: ["NVIDIA_API_KEY", "NGC_API_KEY"], protocol: "openai_chat"),
      Definition.new(id: "openai", name: "OpenAI", api_key_env: ["OPENAI_API_KEY"], protocol: "openai_responses", oauth_name: "ChatGPT"),
      Definition.new(id: "openrouter", name: "OpenRouter", api_key_env: ["OPENROUTER_API_KEY"], protocol: "openai_chat", oauth_name: "OpenRouter"),
      Definition.new(id: "together", name: "Together AI", api_key_env: ["TOGETHER_API_KEY"], protocol: "openai_chat"),
      Definition.new(id: "xai", name: "xAI", api_key_env: ["XAI_API_KEY"], protocol: "openai_chat", oauth_name: "xAI Grok"),
      Definition.new(id: "copilot", name: "GitHub Copilot", api_key_env: [], protocol: "copilot", oauth_name: "GitHub Copilot")
    ].freeze
    CONFIGURATION_IDS = (["codex", "openai_api", "local"] + DEFINITIONS.map(&:id).reject { |id| id == "openai" }).freeze

    module_function

    def configuration_ids
      CONFIGURATION_IDS
    end

    def all
      DEFINITIONS
    end

    def fetch(id)
      find(id) || raise(ArgumentError, "Unknown provider: #{id}")
    end

    def find(id)
      DEFINITIONS.find { |provider| provider.id == id.to_s }
    end

    def find_by_name(name)
      DEFINITIONS.find { |provider| provider.name.casecmp?(name.to_s) }
    end

    def runtime(id)
      provider = fetch(id)
      runtime_id = provider.id == "openai" ? "openai_api" : provider.id
      Runtime.new(
        id: runtime_id,
        model_config_key: "#{runtime_id}_model",
        reasoning_config_key: "#{runtime_id}_reasoning_effort",
        chat_url: CHAT_URLS[provider.id],
        model_list_url: MODEL_LIST_URLS[provider.id],
        model_discovery: provider.id == "azure_openai" ? :configured : (MODEL_LIST_URLS.key?(provider.id) ? :live : :curated)
      )
    end

    def api_key_providers
      DEFINITIONS.select(&:api_key?)
    end

    def oauth_providers
      DEFINITIONS.select(&:oauth?)
    end
  end
end
