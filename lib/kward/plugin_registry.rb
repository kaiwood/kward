require_relative "config_files"
require_relative "deep_copy"
require_relative "hooks"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Loads trusted user plugin files and provides the plugin DSL.
  #
  # Plugins live in the user plugin directory, run as local Ruby code, and can
  # register slash commands, one footer renderer, prompt context, and live
  # transcript-event observers for CLI and RPC frontends.
  #
  # This registry is intentionally trust-based, not a sandbox. Keep plugin loading
  # restricted to `ConfigFiles.plugin_paths`, keep workspace-local code out of the
  # load path, and expose immutable transcript views so plugins can observe state
  # without corrupting active conversations.
  class PluginRegistry
    COMMAND_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.freeze

    # Registered slash command exposed in completion, RPC command listings, and
    # interactive command dispatch.
    Command = Struct.new(:name, :description, :argument_hint, :path, :handler, keyword_init: true) do
      def entry
        { name: name, description: description, argument_hint: argument_hint }
      end
    end

    # Registered interactive command that takes over the composer region with a
    # Kward-driven render and input loop. Like a slash command but with canvas
    # rendering capabilities for games, dashboards, viewers, and similar uses.
    InteractiveCommand = Struct.new(:name, :description, :argument_hint, :rows, :fps, :path, :handler, keyword_init: true) do
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

    # Registered lifecycle hook handler.
    HookHandler = Struct.new(:event, :id, :description, :path, :order, :match, :failure_policy, :handler, keyword_init: true)

    # Read-only transcript view exposed to plugin code.
    class Transcript
      # Creates an object for trusted plugin loading and dispatch.
      def initialize(conversation)
        @conversation = conversation
      end

      # Returns a deep-frozen copy of the active conversation messages.
      #
      # @return [Array<Hash>] immutable transcript message data
      def messages
        DeepCopy.freeze(DeepCopy.dup(@conversation.messages))
      end
    end

    # Runtime context passed to plugin commands, footers, prompt context
    # renderers, and transcript event handlers.
    class Context
      attr_reader :args, :workspace_root

      # Creates an object for trusted plugin loading and dispatch.
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

      # @return [String, nil] active session identifier
      def session_id
        @session&.id
      end

      # @return [String, nil] human-readable active session name
      def session_name
        @session&.name
      end

      # @return [String, nil] saved active session path
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

      # Allows the current lifecycle event to continue.
      # @return [Hooks::Decision]
      def allow(message = nil, metadata: nil)
        Hooks::Decision.allow(message, metadata: metadata)
      end

      # Denies the current lifecycle event.
      # @return [Hooks::Decision]
      def deny(message = nil, metadata: nil)
        Hooks::Decision.deny(message, metadata: metadata)
      end

      # Requests frontend approval for the current lifecycle event.
      # @return [Hooks::Decision]
      def ask(message = nil, metadata: nil)
        Hooks::Decision.ask(message, metadata: metadata)
      end

      # Continues with an event-specific payload replacement.
      # @param payload [Hash] replacement fields supported by the event
      # @return [Hooks::Decision]
      def modify(payload, message: nil, metadata: nil)
        Hooks::Decision.modify(payload, message: message, metadata: metadata)
      end

      # Allows the event while recording a warning.
      # @return [Hooks::Decision]
      def warn(message = nil, metadata: nil)
        Hooks::Decision.warn(message, metadata: metadata)
      end

      # Requests a retry when the current event supports it.
      # @return [Hooks::Decision]
      def retry(message = nil, payload: nil, metadata: nil)
        Hooks::Decision.retry(message, payload: payload, metadata: metadata)
      end

      # Defers the event when the current workflow supports it.
      # @return [Hooks::Decision]
      def defer(message = nil, payload: nil, metadata: nil)
        Hooks::Decision.defer(message, payload: payload, metadata: metadata)
      end
    end

    # Public DSL object yielded by `Kward.plugin` blocks.
    #
    # Plugin files normally interact with this object only through a block:
    #
    # @example Register a plugin command
    #   Kward.plugin do |plugin|
    #     plugin.command "hello", description: "Say hello" do |args, ctx|
    #       name = args.strip.empty? ? "there" : args.strip
    #       ctx.say "Hello, #{name}."
    #     end
    #   end
    #
    # @api public
    class DSL
      # Creates an object for trusted plugin loading and dispatch.
      def initialize(registry, path)
        @registry = registry
        @path = path
      end

      # Registers a slash command.
      #
      # The command is available in the interactive CLI and through the RPC
      # command bridge. Command names do not include the leading `/`.
      #
      # @param name [String, #to_s] command name without the leading slash
      # @param description [String] short text shown in command listings
      # @param argument_hint [String] optional usage hint for arguments
      # @yieldparam args [String] text after the command name
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def command(name, description: "", argument_hint: "", &block)
        @registry.register_command(name, description: description, argument_hint: argument_hint, path: @path, &block)
      end

      # Registers or replaces the custom footer renderer.
      #
      # Only one footer renderer is active. If multiple plugins register one,
      # the later renderer replaces the earlier renderer.
      #
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def footer(&block)
        @registry.register_footer(path: @path, &block)
      end

      # Registers a live transcript event observer.
      #
      # Observer errors are caught and reported as warnings so a plugin cannot
      # crash the active turn by raising from an event handler.
      #
      # @yieldparam event [TranscriptEvent] normalized transcript event
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def on_transcript_event(&block)
        @registry.register_transcript_event(path: @path, &block)
      end

      # Registers a lifecycle hook handler.
      #
      # Hooks are deterministic runtime callbacks around Kward lifecycle events.
      # They can return a {Hooks::Decision}, a decision hash, a decision string,
      # or nil to allow the operation.
      #
      # @param event [String, #to_s] lifecycle event name
      # @param id [String, nil] stable hook identifier for logs and diagnostics
      # @param description [String] short human-readable purpose
      # @param order [Integer] lower values run first
      # @param match [Hash, nil] optional event selector
      # @yieldparam event [Hooks::Event] immutable lifecycle event
      # @yieldparam ctx [Context] plugin execution context and decision helpers
      # @return [void]
      # @api public
      def hook(event, id: nil, description: "", order: 100, match: nil, failure_policy: nil, &block)
        @registry.register_hook(event, id: id, description: description, order: order, match: match, failure_policy: failure_policy, path: @path, &block)
      end

      # Registers prompt context text injected into future system prompts.
      #
      # Keep this text short and never include secrets. The returned string can
      # be sent to the active model as part of Kward's system instructions.
      #
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def prompt_context(&block)
        @registry.register_prompt_context(path: @path, &block)
      end

      # Registers an interactive command that takes over the composer region with
      # a Kward-driven render and input loop. The handler receives an
      # interactive controller object with a canvas API for drawing colored
      # cells and reading keys. Useful for games, dashboards, and viewers.
      #
      # @param name [String, #to_s] command name without the leading slash
      # @param rows [Integer] fixed canvas height in terminal rows
      # @param fps [Numeric] frame rate for tick callbacks (1-120, default 30)
      # @param description [String] short text shown in command listings
      # @param argument_hint [String] optional usage hint for arguments
      # @yieldparam ui [Object] interactive controller with canvas and key API
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def interactive_command(name, rows:, fps: 30, description: "", argument_hint: "", &block)
        @registry.register_interactive_command(name, rows: rows, fps: fps, description: description, argument_hint: argument_hint, path: @path, &block)
      end
    end

    # Mutable singleton guard used while loading trusted plugin files.
    class << self
      attr_accessor :loading_registry, :loading_path

      def load(paths: ConfigFiles.plugin_paths, reserved_commands: [])
        registry = new(reserved_commands: reserved_commands)
        paths.each { |path| registry.load_file(path) }
        registry
      end
    end

    # Creates an object for trusted plugin loading and dispatch.
    def initialize(reserved_commands: [])
      @reserved_commands = reserved_commands.map(&:to_s)
      @commands = {}
      @interactive_commands = {}
      @footer = nil
      @footer_path = nil
      @transcript_event_handlers = []
      @prompt_context_renderers = []
      @hook_handlers = []
      @paths = []
    end

    # @return [String, nil] plugin file currently responsible for footer output
    attr_reader :footer_path

    # @return [Array<String>] plugin files successfully loaded by this registry
    attr_reader :paths

    def commands
      @commands.values
    end

    def command_for(name)
      @commands[name.to_s]
    end

    def interactive_commands
      @interactive_commands.values
    end

    def interactive_command_for(name)
      @interactive_commands[name.to_s]
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

    def hook_handlers
      @hook_handlers.dup
    end

    def hook_manager
      manager = Hooks::Manager.new
      @hook_handlers.each do |hook|
        manager.register(hook.event, id: hook.id, source: hook.path, order: hook.order, match: hook.match, failure_policy: hook.failure_policy) do |event, context|
          hook.handler.call(event, context)
        end
      end
      manager
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
      @paths << path
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

    def register_interactive_command(name, rows:, fps: 30, description: "", argument_hint: "", path: nil, &handler)
      name = name.to_s
      raise "Interactive command name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Interactive command /#{name} requires a handler" unless handler

      if @reserved_commands.include?(name) || @commands.key?(name)
        warn "Warning: skipping Kward interactive command /#{name}: reserved command"
        return nil
      end
      if @interactive_commands.key?(name)
        warn "Warning: skipping duplicate Kward interactive command /#{name}: #{path}"
        return nil
      end

      @interactive_commands[name] = InteractiveCommand.new(
        name: name,
        description: description.to_s,
        argument_hint: argument_hint.to_s,
        rows: [[rows.to_i, 1].max, 1].max,
        fps: [[fps.to_f, 1].max, 120].min,
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

    def register_hook(event, id: nil, description: "", order: 100, match: nil, failure_policy: nil, path: nil, &handler)
      event = event.to_s
      raise "Plugin hook event is required" if event.empty?
      raise "Plugin hook #{event} requires a handler" unless handler

      @hook_handlers << HookHandler.new(
        event: event,
        id: id&.to_s || "#{File.basename(path.to_s.empty? ? "plugin" : path)}:#{event}:#{@hook_handlers.length + 1}",
        description: description.to_s,
        path: path,
        order: order.to_i,
        match: match,
        failure_policy: failure_policy,
        handler: handler
      )
    end

    private

    def transcript_event_for(event)
      case event.class.name
      when "Kward::Events::ReasoningDelta"
        transcript_event("reasoning_delta", delta: event.delta)
      when "Kward::Events::ReasoningBoundary"
        transcript_event("reasoning_boundary")
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
        payload: DeepCopy.freeze(DeepCopy.dup(payload))
      ).freeze
    end
  end

  # Registers a trusted local plugin.
  #
  # This method is intended for Ruby files loaded from the user plugin
  # directory. It raises if called outside plugin loading so workspace code
  # cannot silently mutate Kward's runtime by merely being required.
  #
  # @yieldparam plugin [PluginRegistry::DSL] plugin registration DSL
  # @return [Object, nil] the plugin block result
  # @api public
  def self.plugin(&block)
    registry = PluginRegistry.loading_registry
    raise "Kward.plugin can only be called while loading a plugin" unless registry

    dsl = PluginRegistry::DSL.new(registry, PluginRegistry.loading_path)
    block.arity == 1 ? block.call(dsl) : dsl.instance_eval(&block)
  end
end
