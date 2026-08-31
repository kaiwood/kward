# CLI settings model behavior.
module Kward
  class CLI
    module Settings
      module Model
        private

        def configure_model(conversation = nil, models: nil)
          unless model_overlay_available?
            runtime_output("Model overlay is unavailable in this prompt.")
            return
          end

          models ||= normalized_available_models(conversation)
          provider_filter = nil
          show_all = false
          loop do
            visible_models = provider_filter ? models.select { |model| model[:provider] == provider_filter } : models
            visible_models = visible_models.select { |model| default_selectable_model?(model) } unless show_all
            actions = ["Refresh model list", "Enter model ID manually", "Show all models", "Change provider"]
            selected = @prompt.select("Default model", model_choices(visible_models, conversation) + actions, title: "Models", custom: true)
            return unless selected

            case selected.to_s
            when "Refresh model list"
              refreshed = @client.refresh_available_models(provider: provider_filter) if @client.respond_to?(:refresh_available_models)
              models = normalized_available_models(conversation, models: refreshed)
            when "Enter model ID manually"
              provider = provider_filter || conversation&.provider || current_model_provider
              model = @prompt.select("Model ID for #{provider}", [], title: "Models", custom: true)
              return unless model
              persist_model_selection(provider, model, conversation)
              return
            when "Show all models"
              provider_filter = nil
              show_all = true
            when "Change provider"
              selected_provider_name = selected_provider(@prompt.select("Provider", provider_choices, title: "Models"))
              if selected_provider_name
                provider_filter = selected_provider_name
                show_all = false
              end
            else
              provider, model = selected_model(selected, models)
              persist_model_selection(provider, model, conversation)
              return
            end
          end
        rescue StandardError => e
          runtime_output("Model error: #{e.message}")
        end

        def configure_reasoning(conversation = nil)
          unless model_overlay_available?
            runtime_output("Reasoning overlay is unavailable in this prompt.")
            return
          end

          provider = conversation&.provider || current_model_provider
          model = conversation&.model || current_model_id
          choices = ModelInfo.reasoning_effort_choices(provider, model)
          if choices.empty?
            runtime_output("Reasoning effort is unavailable for #{provider} #{model}.")
            return
          end

          selected = @prompt.select("Reasoning effort", reasoning_choices(choices, conversation), title: "Reasoning")
          return unless selected

          effort, = choices.find { |_value, label| selected.to_s.downcase.start_with?(label.downcase) }
          raise "Reasoning effort must be one of: #{choices.map(&:first).join(", ")}" unless effort

          set_reasoning_effort(effort, conversation, provider: provider)
        rescue StandardError => e
          runtime_output("Reasoning error: #{e.message}")
        end

        def login_picker_available?
          @prompt.respond_to?(:select)
        end

        def login_method_choices
          ["API key", "Subscription / OAuth"]
        end

        def selected_login_method(selected)
          case selected.to_s.downcase
          when /\Aapi key\z/ then :api_key
          when /\Asubscription \/ oauth\z/ then :oauth
          end
        end

        def login_provider_prompt(method)
          method == :api_key ? "Add an API key" : "Sign in with a subscription"
        end

        def login_provider_choices(method)
          if method == :api_key
            ProviderCatalog.api_key_providers.map(&:name)
          else
            ["Anthropic Claude", "ChatGPT", "GitHub Copilot"]
          end
        end

        def selected_login_provider(selected)
          value = selected.to_s.downcase
          return "openai" if value == "openai" || value == "chatgpt"
          return "anthropic" if value == "anthropic" || value == "anthropic claude"
          return "copilot" if value == "github copilot"

          ProviderCatalog.find_by_name(selected)&.id
        end

        def model_overlay_available?
          @prompt.respond_to?(:select)
        end

        def settings_overlay_available?
          @prompt.respond_to?(:select)
        end

        def update_overlay_settings(values)
          settings = ConfigFiles.update_overlay_settings(values)
          @prompt.update_overlay_settings(settings) if @prompt.respond_to?(:update_overlay_settings)
          settings
        end

        def choose_overlay_setting(message, choices, values)
          choice = @prompt.select(message, choices, title: "Settings")
          return nil unless choice

          values.find { |value| choice.to_s.downcase.start_with?(value) }
        end

        def normalized_available_models(conversation = current_footer_conversation, models: nil)
          current_provider = conversation.provider || (@client.respond_to?(:current_provider) ? @client.current_provider : "Codex")
          current_model = conversation.model || (@client.respond_to?(:current_model) ? @client.current_model : nil)
          current_reasoning = conversation.reasoning_effort || (@client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : nil)
          models ||= @client.respond_to?(:available_models) ? @client.available_models : []
          ModelInfo.normalize_available(
            models,
            current_provider: current_provider,
            current_model: current_model,
            current_reasoning_effort: current_reasoning
          )
        end

        def model_choices(models, conversation = current_footer_conversation)
          current_provider = conversation.provider || current_model_provider
          current_model = conversation.model || current_model_id
          choices = models.map do |model|
            label = "#{model[:provider]} #{model[:id]}"
            label += " (current)" if model[:current]
            label
          end
          choices.empty? ? ["#{current_provider} #{current_model} (current)"] : choices.uniq
        end

        def default_selectable_model?(model)
          return true if model[:current]

          capabilities = Array(model[:supportedParameters]).map { |value| value.to_s.downcase }
          return true if capabilities.empty?

          capabilities.any? do |capability|
            ["tools", "toolchoice", "functioncalling", "generatecontent", "streamgeneratecontent"].include?(capability.delete("_-"))
          end
        end

        def selected_model(selected, models)
          text = selected.to_s.sub(/ \(current\)\z/, "").strip
          known = models.find { |model| "#{model[:provider]} #{model[:id]}" == text }
          return [known[:provider], known[:id]] if known

          provider, model = text.split(/\s+/, 2)
          known_provider = ["Codex", "Anthropic", "OpenRouter", "Copilot", "Local"].include?(provider) || ProviderCatalog.find_by_name(provider)
          return [provider, model.strip] if known_provider && !model.to_s.strip.empty?

          [current_model_provider, text]
        end

        def persist_model_selection(provider, model, conversation)
          model = model.to_s.strip
          raise "Model must be a non-empty string" if model.empty?

          ConfigFiles.update_config(ModelInfo.config_values_for_selection(provider, model))
          reload_client_config
          refresh_conversation_runtime(conversation)
          refresh_composer_status
        end

        REASONING_CONFIG_DEBOUNCE_SECONDS = 0.5

        def cycle_reasoning(conversation = current_footer_conversation, direction: :next, persist: :immediate)
          provider = conversation&.provider || current_model_provider
          model = conversation&.model || current_model_id
          choices = ModelInfo.reasoning_effort_choices(provider, model)
          return false if choices.empty?

          current = (pending_reasoning_effort(provider) || conversation&.reasoning_effort || current_reasoning_effort).to_s
          current_index = choices.index { |effort, _label| effort == current }
          current_index ||= direction == :previous ? 0 : -1
          offset = direction == :previous ? -1 : 1
          effort = choices[(current_index + offset) % choices.length].first
          persist == :debounced ? apply_reasoning_effort(effort, conversation, provider: provider) : set_reasoning_effort(effort, conversation, provider: provider)
          true
        rescue StandardError => e
          runtime_output("Reasoning error: #{e.message}")
          false
        end

        def set_reasoning_effort(effort, conversation = nil, provider: nil)
          @pending_reasoning_config_mutex.synchronize { @pending_reasoning_config = nil }
          persist_reasoning_config(effort, provider: provider)
          apply_reasoning_effort(effort, conversation, provider: provider, queue_config: false)
        end

        def apply_reasoning_effort(effort, conversation = nil, provider: nil, queue_config: true)
          queue_reasoning_config(effort, provider: provider, conversation: conversation) if queue_config
          if queue_config
            update_conversation_reasoning_effort(conversation, effort)
            refresh_composer_status
          else
            refresh_conversation_runtime(conversation, reasoning_effort: effort)
            refresh_composer_status
          end
        end

        def update_conversation_reasoning_effort(conversation, effort)
          return unless conversation&.respond_to?(:update_runtime_context!)

          conversation.update_runtime_context!(
            provider: conversation.provider || current_model_provider,
            model: conversation.model || current_model_id,
            reasoning_effort: effort,
            refresh: false
          )
        end

        def pending_reasoning_effort(provider)
          @pending_reasoning_config_mutex.synchronize do
            pending = @pending_reasoning_config
            return nil unless pending
            return nil unless pending[:provider].to_s.downcase == provider.to_s.downcase

            pending[:effort]
          end
        end

        def queue_reasoning_config(effort, provider: nil, conversation: nil)
          pending = {
            effort: effort,
            provider: provider || current_model_provider,
            conversation: conversation,
            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + REASONING_CONFIG_DEBOUNCE_SECONDS
          }
          @pending_reasoning_config_mutex.synchronize { @pending_reasoning_config = pending }
          schedule_reasoning_config_flush
        end

        def schedule_reasoning_config_flush
          return if @pending_reasoning_config_thread&.alive?

          @pending_reasoning_config_thread = Thread.new do
            loop do
              sleep REASONING_CONFIG_DEBOUNCE_SECONDS
              break if flush_pending_reasoning_config(force: false)
              break unless @pending_reasoning_config_mutex.synchronize { @pending_reasoning_config }
            end
          rescue StandardError => e
            runtime_output("Reasoning error: #{e.message}")
          end
        end

        def flush_pending_reasoning_config(force: true, conversation: nil)
          pending = nil
          @pending_reasoning_config_mutex.synchronize do
            pending = @pending_reasoning_config
            return false unless pending

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if !force && now < pending[:deadline].to_f

            @pending_reasoning_config = nil
          end
          persist_reasoning_config(pending[:effort], provider: pending[:provider])
          conversation ||= pending[:conversation]
          if conversation&.reasoning_effort.to_s == pending[:effort].to_s
            refresh_conversation_runtime(conversation, reasoning_effort: pending[:effort])
            conversation.persist_runtime_context! if conversation.respond_to?(:persist_runtime_context!)
          end
          true
        end

        def persist_reasoning_config(effort, provider: nil)
          ConfigFiles.update_config(ModelInfo.reasoning_config_key_for_provider(provider || current_model_provider) => effort)
          reload_client_config
        end

        def reasoning_choices(choices, conversation = current_footer_conversation)
          current = (conversation.reasoning_effort || (@client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT)).to_s
          choices.map do |effort, label|
            text = label.dup
            text += " (current)" if current == effort
            text
          end
        end

        def overlay_alignment_choices(settings)
          ConfigFiles::OVERLAY_ALIGNMENTS.map do |alignment|
            label = alignment.capitalize
            label += " (current)" if settings["alignment"] == alignment
            label
          end
        end

        def overlay_width_choices(settings)
          ConfigFiles::OVERLAY_WIDTHS.map do |width|
            label = width.capitalize
            label += " (current)" if settings["width"] == width
            label
          end
        end
      end
    end
  end
end
