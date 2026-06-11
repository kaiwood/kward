require_relative "config_files"

module Kward
  # Loads trusted user plugin files and provides the plugin DSL.
  #
  # Plugins live in the user plugin directory, run as local Ruby code, and can
  # register slash commands, one footer renderer, prompt context, and live
  # transcript-event observers for CLI and RPC frontends.
  class PluginRegistry
    COMMAND_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.freeze

    # Registered slash command exposed in completion, RPC command listings, and
    # interactive command dispatch.
    Command = Struct.new(:name, :description, :argument_hint, :path, :handler, keyword_init: true) do
      def entry
        { name: name, description: description, argument_hint: argument_hint }
      end
    end

    # Read-only event passed to plugin transcript observers.
    TranscriptEvent = Struct.new(:type, :payload, keyword_init: true) do
      def to_h
        { type: type, payload: payload }
      end
    end

    # Read-only transcript view exposed to plugin code.
    class Transcript
      def initialize(conversation)
        @conversation = conversation
      end

      # Returns a deep-frozen copy of the active conversation messages.
      #
      # @return [Array<Hash>] immutable transcript message data
      def messages
        PluginRegistry.deep_freeze(PluginRegistry.deep_dup(@conversation.messages))
      end
    end

    # Runtime context passed to plugin commands, footers, prompt context
    # renderers, and transcript event handlers.
    class Context
      attr_reader :args, :workspace_root

      def initialize(conversation:, args: "", session: nil, workspace_root: Dir.pwd, say_callback: nil)
        @conversation = conversation
        @args = args.to_s
        @session = session
        @workspace_root = workspace_root
        @say_callback = say_callback
      end

      # @return [Transcript] read-only transcript wrapper
      def transcript
        Transcript.new(@conversation)
      end

      # Emits command output to the active frontend when available.
      #
      # @param message [#to_s] message to display
      # @return [nil]
      def say(message)
        @say_callback&.call(message.to_s)
        nil
      end

      def session_id
        @session&.id
      end

      def session_name
        @session&.name
      end

      def session_path
        @session&.path
      end

      # Requests that the conversation rebuild its system message after plugin
      # state changes that affect prompt context.
      #
      # @return [nil]
      def refresh_system_message!
        @conversation.refresh_system_message! if @conversation.respond_to?(:refresh_system_message!)
        nil
      end
    end

    # DSL object yielded by `Kward.plugin` blocks.
    class DSL
      def initialize(registry, path)
        @registry = registry
        @path = path
      end

      # Registers a slash command.
      #
      # @param name [String, #to_s] command name without the leading slash
      # @param description [String] short text shown in command listings
      # @param argument_hint [String] optional usage hint for arguments
      # @yieldparam args [String] text after the command name
      # @yieldparam ctx [Context] plugin execution context
      def command(name, description: "", argument_hint: "", &block)
        @registry.register_command(name, description: description, argument_hint: argument_hint, path: @path, &block)
      end

      # Registers or replaces the custom footer renderer.
      #
      # @yieldparam ctx [Context] plugin execution context
      def footer(&block)
        @registry.register_footer(path: @path, &block)
      end

      # Registers a live transcript event observer.
      #
      # @yieldparam event [TranscriptEvent] normalized transcript event
      # @yieldparam ctx [Context] plugin execution context
      def on_transcript_event(&block)
        @registry.register_transcript_event(path: @path, &block)
      end

      # Registers prompt context text injected into future system prompts.
      #
      # @yieldparam ctx [Context] plugin execution context
      def prompt_context(&block)
        @registry.register_prompt_context(path: @path, &block)
      end
    end

    class << self
      attr_accessor :loading_registry, :loading_path

      def load(paths: ConfigFiles.plugin_paths, reserved_commands: [])
        registry = new(reserved_commands: reserved_commands)
        paths.each { |path| registry.load_file(path) }
        registry
      end

      def deep_dup(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key] = deep_dup(item) }
        when Array
          value.map { |item| deep_dup(item) }
        else
          value.dup
        end
      rescue TypeError
        value
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_value { |item| deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end

    def initialize(reserved_commands: [])
      @reserved_commands = reserved_commands.map(&:to_s)
      @commands = {}
      @footer = nil
      @footer_path = nil
      @transcript_event_handlers = []
      @prompt_context_renderers = []
    end

    attr_reader :footer_path

    def commands
      @commands.values
    end

    def command_for(name)
      @commands[name.to_s]
    end

    def footer_renderer
      @footer
    end

    def transcript_event_handlers
      @transcript_event_handlers.map { |entry| entry[:handler] }
    end

    def prompt_context_renderers
      @prompt_context_renderers.map { |entry| entry[:renderer] }
    end

    def prompt_context(context)
      parts = []
      @prompt_context_renderers.each do |entry|
        rendered = entry[:renderer].call(context)
        parts << rendered.to_s unless rendered.to_s.empty?
      rescue StandardError => e
        warn "Warning: Kward plugin prompt context error in #{entry[:path]}: #{e.message}"
      end
      parts.empty? ? nil : parts.join("\n\n")
    end

    def notify_transcript_event(event, context)
      transcript_event = transcript_event_for(event)
      return unless transcript_event

      @transcript_event_handlers.each do |entry|
        entry[:handler].call(transcript_event, context)
      rescue StandardError => e
        warn "Warning: Kward plugin transcript event error in #{entry[:path]}: #{e.message}"
      end
      nil
    end

    def load_file(path)
      previous_registry = self.class.loading_registry
      previous_path = self.class.loading_path
      self.class.loading_registry = self
      self.class.loading_path = path
      Kernel.load(path)
    rescue StandardError => e
      warn "Warning: skipping Kward plugin #{path}: #{e.message}"
    ensure
      self.class.loading_registry = previous_registry
      self.class.loading_path = previous_path
    end

    def evaluate(path: nil, &block)
      dsl = DSL.new(self, path)
      block.arity == 1 ? block.call(dsl) : dsl.instance_eval(&block)
      self
    end

    def register_command(name, description: "", argument_hint: "", path: nil, &handler)
      name = name.to_s
      raise "Plugin command name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Plugin command /#{name} requires a handler" unless handler

      if @reserved_commands.include?(name)
        warn "Warning: skipping Kward plugin command /#{name}: reserved command"
        return nil
      end
      if @commands.key?(name)
        warn "Warning: skipping duplicate Kward plugin command /#{name}: #{path}"
        return nil
      end

      @commands[name] = Command.new(
        name: name,
        description: description.to_s,
        argument_hint: argument_hint.to_s,
        path: path,
        handler: handler
      )
    end

    def register_footer(path: nil, &renderer)
      raise "Plugin footer requires a renderer" unless renderer

      warn "Warning: replacing Kward plugin footer from #{@footer_path}: #{path}" if @footer
      @footer = renderer
      @footer_path = path
    end

    def register_transcript_event(path: nil, &handler)
      raise "Plugin transcript event requires a handler" unless handler

      @transcript_event_handlers << { path: path, handler: handler }
    end

    def register_prompt_context(path: nil, &renderer)
      raise "Plugin prompt context requires a renderer" unless renderer

      @prompt_context_renderers << { path: path, renderer: renderer }
    end

    private

    def transcript_event_for(event)
      case event.class.name
      when "Kward::Events::ReasoningDelta"
        transcript_event("reasoning_delta", delta: event.delta)
      when "Kward::Events::AssistantDelta"
        transcript_event("assistant_delta", delta: event.delta)
      when "Kward::Events::AssistantMessage"
        transcript_event("assistant_message", message: event.message)
      when "Kward::Events::Retry"
        transcript_event(
          "model_retry",
          provider: event.provider,
          model: event.model,
          attempt: event.attempt,
          max_attempts: event.max_attempts,
          delay_seconds: event.delay_seconds,
          error: event.error,
          request_bytes: event.request_bytes
        )
      when "Kward::Events::Steering"
        transcript_event("turn_steered", input: event.input, created_at: event.created_at)
      when "Kward::Events::ToolCall"
        transcript_event("tool_call", tool_call: event.tool_call)
      when "Kward::Events::ToolResult"
        transcript_event("tool_result", tool_call: event.tool_call, content: event.content)
      when "Kward::Events::Answer"
        transcript_event("answer", content: event.content)
      end
    end

    def transcript_event(type, payload)
      TranscriptEvent.new(
        type: type,
        payload: PluginRegistry.deep_freeze(PluginRegistry.deep_dup(payload))
      ).freeze
    end
  end

  def self.plugin(&block)
    registry = PluginRegistry.loading_registry
    raise "Kward.plugin can only be called while loading a plugin" unless registry

    dsl = PluginRegistry::DSL.new(registry, PluginRegistry.loading_path)
    block.arity == 1 ? block.call(dsl) : dsl.instance_eval(&block)
  end
end
