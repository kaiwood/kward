require_relative "../config_files"
require_relative "../deep_copy"
require_relative "../hooks"
require_relative "../transport"
require_relative "actions"
require_relative "host"
require_relative "ui"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Loads trusted user plugin files and provides the plugin DSL.
  #
  # Plugins live in the user plugin directory, run as local Ruby code, and can
  # register slash commands, namespaced actions, model-callable tools, lifecycle
  # callbacks, one footer renderer, prompt context, and live transcript-event
  # observers for CLI and RPC frontends.
  #
  # This registry is intentionally trust-based, not a sandbox. Keep plugin loading
  # restricted to `ConfigFiles.plugin_paths`, keep workspace-local code out of the
  # load path, and expose immutable transcript views so plugins can observe state
  # without corrupting active conversations.
  class PluginRegistry
    PLUGIN_API_VERSION = "1"
    COMMAND_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.freeze

    # Public registration types retained under the registry namespace.
    Command = PluginCommand
    Action = PluginAction

    # Registered model-callable tool exposed through each normal agent tool
    # registry. The handler receives parsed arguments and a runtime context.
    Tool = Struct.new(:name, :description, :schema, :path, :handler, keyword_init: true)

    # Registered interactive command that takes over the composer region with a
    # Kward-driven render and input loop. Like a slash command but with canvas
    # rendering capabilities for games, dashboards, viewers, and similar uses.
    InteractiveCommand = Struct.new(:name, :description, :argument_hint, :rows, :fps, :path, :handler, keyword_init: true) do
      def entry
        { name: name, description: description, argument_hint: argument_hint }
      end
    end

    # Registered plugin-owned tab runtime. Its factory receives a
    # `PluginTabHost` and its persisted descriptor, then returns a driver.
    TabType = Struct.new(:id, :name, :title, :singleton, :rpc, :transport, :local, :transcript_events, :path, :handler, keyword_init: true)

    # Registered external transport. The factory receives a transport host and
    # configuration when the transport is started, not while plugins load.
    TransportType = Struct.new(:id, :name, :capabilities, :execution_profile, :path, :handler, keyword_init: true)

    # Read-only event passed to plugin transcript observers.
    TranscriptEvent = Struct.new(:type, :payload, keyword_init: true) do
      def to_h
        { type: type, payload: payload }
      end
    end

    # Registered lifecycle hook handler.
    HookHandler = Struct.new(:event, :id, :description, :path, :order, :match, :failure_policy, :handler, keyword_init: true)

    # Plugin-runtime callback invoked when an identified plugin starts, reloads,
    # or shuts down.
    LifecycleHandler = Struct.new(:event, :host, :path, :handler, keyword_init: true)

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

    # Runtime context passed to plugin commands, tools, footers, prompt context
    # renderers, hooks, and transcript event handlers.
    class Context
      attr_reader :args, :workspace_root, :cancellation, :ui

      # Creates an object for trusted plugin loading and dispatch.
      def initialize(conversation:, args: "", session: nil, workspace_root: Dir.pwd, say_callback: nil, cancellation: nil, ui: nil, tool_ui: nil)
        @conversation = conversation
        @args = args.is_a?(Hash) ? DeepCopy.freeze(DeepCopy.dup(args)) : args.to_s
        @session = session
        @workspace_root = workspace_root
        @say_callback = say_callback
        @cancellation = cancellation
        @ui = (ui || PluginUI.new(say_callback: say_callback)).with_cancellation(cancellation)
        @tool_ui = tool_ui
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

      # Builds a structured result for a typed command or plugin action.
      #
      # @param message [#to_s, nil] optional user-facing result text
      # @param data [Object, nil] optional JSON-compatible machine-readable data
      # @return [PluginResult]
      def result(message: nil, data: nil)
        PluginResult.new(message: message, data: data)
      end

      # Returns whether the active plugin operation has been cancelled.
      # Contexts without a cancellable operation return false.
      def cancelled?
        @cancellation&.cancelled? == true
      end

      # Builds a fresh context for one model-callable plugin tool invocation.
      # @api private
      def for_tool(conversation:, cancellation: nil)
        self.class.new(
          conversation: conversation,
          session: @session,
          workspace_root: @workspace_root,
          say_callback: @say_callback,
          cancellation: cancellation,
          ui: @tool_ui || @ui
        )
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
      def initialize(registry, path, host: nil)
        @registry = registry
        @path = path
        @host = host
      end

      # Shared metadata, configuration, storage, secrets, and logging services.
      # Legacy plugins without declared identity return nil.
      #
      # @return [PluginHost, nil]
      attr_reader :host

      # Registers a slash command.
      #
      # The command is available in the interactive CLI and through the RPC
      # command bridge. Command names do not include the leading `/`.
      #
      # @param name [String, #to_s] command name without the leading slash
      # @param description [String] short text shown in command listings
      # @param argument_hint [String] optional usage hint for arguments
      # @param schema [Hash, nil] strict object JSON Schema for typed arguments
      # @param positionals [Array<String, Symbol>] schema properties filled by positional text
      # @yieldparam args [String, Hash] raw text for legacy commands or parsed typed arguments
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def command(name, description: "", argument_hint: "", schema: nil, positionals: [], &block)
        @registry.register_command(
          name,
          description: description,
          argument_hint: argument_hint,
          schema: schema,
          positionals: positionals,
          plugin_id: @host&.id,
          path: @path,
          &block
        )
      end

      # Registers a namespaced typed action for trusted RPC clients.
      # Identified plugin metadata is required so the action has a stable ID.
      #
      # @param name [String, #to_s] action name within the plugin namespace
      # @param description [String] short client-facing description
      # @param schema [Hash] strict object JSON Schema for typed arguments
      # @yieldparam args [Hash] validated action arguments
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def action(name, description:, schema: { type: "object", properties: {} }, &block)
        raise ArgumentError, "Plugin actions require stable plugin identity" unless @host

        @registry.register_action(name, plugin_id: @host.id, description: description, schema: schema, path: @path, &block)
      end

      # Registers a model-callable tool for normal Kward agent turns.
      #
      # Tool arguments are described with a strict object JSON Schema. The
      # handler must return model-facing text and receives the normal plugin
      # context with the active cancellation token.
      #
      # @param name [String, #to_s] function name exposed to the model
      # @param description [String] model-facing description of the operation
      # @param schema [Hash] object JSON Schema for parsed tool arguments
      # @yieldparam args [Hash] parsed model-provided arguments
      # @yieldparam ctx [Context] plugin execution context
      # @return [void]
      # @api public
      def tool(name, description:, schema: { type: "object", properties: {} }, &block)
        @registry.register_tool(name, description: description, schema: schema, path: @path, &block)
      end

      # Registers a callback invoked after plugin loading when the runtime is
      # ready to start owned background work.
      #
      # @yieldparam host [PluginHost] identified plugin host and resource owner
      # @return [void]
      # @api public
      def on_start(&block)
        register_lifecycle(:start, &block)
      end

      # Registers a callback invoked on the old plugin instance immediately
      # before its resources are cleaned up during reload.
      #
      # @yieldparam host [PluginHost] identified plugin host and resource owner
      # @return [void]
      # @api public
      def on_reload(&block)
        register_lifecycle(:reload, &block)
      end

      # Registers a callback invoked immediately before plugin resources are
      # cleaned up during process shutdown.
      #
      # @yieldparam host [PluginHost] identified plugin host and resource owner
      # @return [void]
      # @api public
      def on_shutdown(&block)
        register_lifecycle(:shutdown, &block)
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

      # Registers a plugin-owned chat type. `id` is a durable identifier used
      # in persisted tab layouts and transport chat handles and must not change.
      # The factory receives a `PluginTabHost` and a descriptor hash.
      #
      # @param name [String] command name used by `/tab open <name>`
      # @param id [String] stable persisted tab type identifier
      # @param title [String] default tab label
      # @param singleton [Symbol] `:global` for one shared plugin runtime
      # @param rpc [Boolean] expose this chat through trusted local RPC
      # @param transport [Boolean] allow external transport adapters to target this chat
      # @param local [Boolean] expose this chat as an interactive local tab
      # @param transcript_events [Boolean] allow global transcript observers to receive this tab's events
      # @yieldparam host [PluginTabHost] supported host dependencies
      # @yieldparam descriptor [Hash] persisted tab descriptor
      # @return [void]
      # @api public
      def tab_type(name, id:, title: nil, singleton: nil, rpc: false, transport: false, local: true, transcript_events: false, &block)
        @registry.register_tab_type(name, id: id, title: title, singleton: singleton, rpc: rpc, transport: transport, local: local, transcript_events: transcript_events, path: @path, &block)
      end

      # Registers an external messaging or event transport. The factory is
      # called when the transport runtime starts.
      #
      # @param name [String] human-readable transport name
      # @param id [String] stable transport identifier
      # @param capabilities [Hash, Transport::Capabilities] supported features
      # @yieldparam host [Object] transport host
      # @yieldparam config [Object] transport configuration
      # @return [void]
      # @api public
      def transport(name, id:, capabilities: nil, execution_profile: nil, &block)
        @registry.register_transport(name, id: id, capabilities: capabilities, execution_profile: execution_profile, path: @path, &block)
      end

      private

      def register_lifecycle(event, &block)
        raise ArgumentError, "Plugin lifecycle callbacks require stable plugin identity" unless @host

        @registry.register_lifecycle(event, host: @host, path: @path, &block)
      end
    end

    # Mutable singleton guard used while loading trusted plugin files.
    class << self
      attr_accessor :loading_registry, :loading_path

      def load(paths: nil, reserved_commands: [], warning_sink: nil)
        warning_sink ||= ConfigFiles.warning_sink
        paths ||= ConfigFiles.plugin_paths(warning_sink: warning_sink)
        registry = new(reserved_commands: reserved_commands, warning_sink: warning_sink)
        paths.each { |path| registry.load_file(path) }
        registry
      end
    end

    # Creates an object for trusted plugin loading and dispatch.
    def initialize(reserved_commands: [], warning_sink: nil)
      @reserved_commands = reserved_commands.map(&:to_s)
      @warning_sink = warning_sink
      @plugins = {}
      @commands = {}
      @actions = {}
      @tools = {}
      @interactive_commands = {}
      @tab_types = {}
      @tab_types_by_id = {}
      @transports = {}
      @transports_by_id = {}
      @footer = nil
      @footer_path = nil
      @transcript_event_handlers = []
      @prompt_context_renderers = []
      @hook_handlers = []
      @lifecycle_handlers = { start: [], reload: [], shutdown: [] }
      @lifecycle_state = :loaded
      @lifecycle_mutex = Mutex.new
      @paths = []
    end

    # @return [String, nil] plugin file currently responsible for footer output
    attr_reader :footer_path

    # @return [Array<String>] plugin files successfully loaded by this registry
    attr_reader :paths

    # @return [Array<PluginHost>] identified plugins loaded by this registry
    def plugins
      @plugins.values
    end

    def plugin_for(id)
      @plugins[id.to_s]
    end

    def commands
      @commands.values
    end

    def command_for(name)
      @commands[name.to_s]
    end

    def actions
      @actions.values
    end

    def action_for(id)
      @actions[id.to_s]
    end

    def tools
      @tools.values
    end

    def tool_for(name)
      @tools[name.to_s]
    end

    def interactive_commands
      @interactive_commands.values
    end

    def interactive_command_for(name)
      @interactive_commands[name.to_s]
    end

    def tab_types
      @tab_types.values
    end

    def tab_type_for(name)
      @tab_types[name.to_s]
    end

    def tab_type_for_id(id)
      @tab_types_by_id[id.to_s]
    end

    def transport_tab_types
      @tab_types.values.select(&:transport)
    end

    def transports
      @transports.values
    end

    def transport_for(name)
      @transports[name.to_s]
    end

    def transport_for_id(id)
      @transports_by_id[id.to_s]
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

    # Activates identified plugins and invokes their start callbacks once.
    def start!
      transition_lifecycle!(:loaded, :active) do
        @plugins.each_value(&:activate!)
        run_lifecycle_callbacks(:start)
      end
      self
    end

    # Invokes reload callbacks on the old registry and cleans up all resources.
    def reload!(timeout: PluginResources::DEFAULT_SHUTDOWN_TIMEOUT)
      stop_lifecycle!(:reload, timeout: timeout)
    end

    # Invokes shutdown callbacks and cleans up all resources.
    def shutdown!(timeout: PluginResources::DEFAULT_SHUTDOWN_TIMEOUT)
      stop_lifecycle!(:shutdown, timeout: timeout)
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
        emit_warning "Warning: Kward plugin prompt context error in #{entry[:path]}: #{e.message}"
      end
      parts.empty? ? nil : parts.join("\n\n")
    end

    def notify_transcript_event(event, context)
      transcript_event = transcript_event_for(event)
      return unless transcript_event

      @transcript_event_handlers.each do |entry|
        entry[:handler].call(transcript_event, context)
      rescue StandardError => e
        emit_warning "Warning: Kward plugin transcript event error in #{entry[:path]}: #{e.message}"
      end
      nil
    end

    def load_file(path)
      previous_registry = self.class.loading_registry
      previous_path = self.class.loading_path
      self.class.loading_registry = self
      self.class.loading_path = path
      Kernel.load(path, true)
      @paths << path
    rescue StandardError => e
      emit_warning "Warning: skipping Kward plugin #{path}: #{e.message}"
    ensure
      self.class.loading_registry = previous_registry
      self.class.loading_path = previous_path
    end

    def evaluate(path: nil, id: nil, version: nil, api: nil, &block)
      host = register_plugin_identity(id: id, version: version, api: api, path: path)
      dsl = DSL.new(self, path, host: host)
      block.arity == 1 ? block.call(dsl) : dsl.instance_eval(&block)
      self
    end

    def register_plugin_identity(id:, version:, api:, path: nil)
      values = [id, version, api]
      return nil if values.all?(&:nil?)
      raise ArgumentError, "Plugin id, version, and api are required together" if values.any?(&:nil?)

      id = id.to_s
      api = api.to_s
      raise ArgumentError, "Unsupported Kward plugin API #{api.inspect} for #{id}; supported API: #{PLUGIN_API_VERSION}" unless api == PLUGIN_API_VERSION
      raise ArgumentError, "Duplicate Kward plugin id: #{id}" if @plugins.key?(id)

      @plugins[id] = PluginHost.new(
        id: id,
        version: version,
        api_version: api,
        source_path: path,
        warning_sink: method(:emit_warning)
      )
    end

    def register_command(name, description: "", argument_hint: "", schema: nil, positionals: [], plugin_id: nil, path: nil, &handler)
      name = name.to_s
      raise "Plugin command name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Plugin command /#{name} requires a handler" unless handler
      raise ArgumentError, "Plugin command /#{name} positionals require a schema" if schema.nil? && !Array(positionals).empty?

      if @reserved_commands.include?(name)
        emit_warning "Warning: skipping Kward plugin command /#{name}: reserved command"
        return nil
      end
      if @commands.key?(name)
        emit_warning "Warning: skipping duplicate Kward plugin command /#{name}: #{path}"
        return nil
      end

      @commands[name] = Command.new(
        name: name,
        description: description.to_s,
        argument_hint: argument_hint.to_s,
        schema: schema,
        positionals: positionals,
        plugin_id: plugin_id,
        path: path,
        handler: handler
      )
    end

    def register_action(name, plugin_id:, description:, schema:, path: nil, &handler)
      name = name.to_s
      raise "Plugin action name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Plugin action #{plugin_id}/#{name} requires a description" if description.to_s.strip.empty?
      raise "Plugin action #{plugin_id}/#{name} requires a handler" unless handler

      id = "#{plugin_id}/#{name}"
      if @actions.key?(id)
        emit_warning "Warning: skipping duplicate Kward plugin action #{id}: #{path}"
        return nil
      end

      @actions[id] = Action.new(
        name: name,
        plugin_id: plugin_id,
        description: description.to_s,
        schema: schema,
        path: path,
        handler: handler
      )
    end

    def register_tool(name, description:, schema:, path: nil, &handler)
      name = name.to_s
      raise "Plugin tool name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Plugin tool #{name} requires a description" if description.to_s.strip.empty?
      raise "Plugin tool #{name} requires a handler" unless handler

      if @tools.key?(name)
        emit_warning "Warning: skipping duplicate Kward plugin tool #{name}: #{path}"
        return nil
      end

      @tools[name] = Tool.new(
        name: name,
        description: description.to_s,
        schema: normalize_tool_schema(name, schema),
        path: path,
        handler: handler
      )
    end

    def register_interactive_command(name, rows:, fps: 30, description: "", argument_hint: "", path: nil, &handler)
      name = name.to_s
      raise "Interactive command name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Interactive command /#{name} requires a handler" unless handler

      if @reserved_commands.include?(name) || @commands.key?(name)
        emit_warning "Warning: skipping Kward interactive command /#{name}: reserved command"
        return nil
      end
      if @interactive_commands.key?(name)
        emit_warning "Warning: skipping duplicate Kward interactive command /#{name}: #{path}"
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

    def register_tab_type(name, id:, title: nil, singleton: nil, rpc: false, transport: false, local: true, transcript_events: false, path: nil, &handler)
      name = name.to_s
      id = id.to_s
      raise "Plugin tab type name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Plugin tab type id is required" if id.empty?
      raise "Plugin tab type #{name} requires a handler" unless handler

      if @tab_types.key?(name) || @tab_types_by_id.key?(id)
        emit_warning "Warning: skipping duplicate Kward plugin tab type #{id}: #{path}"
        return nil
      end

      tab_type = TabType.new(id: id, name: name, title: title.to_s.empty? ? name.capitalize : title.to_s, singleton: singleton&.to_sym, rpc: rpc == true, transport: transport == true, local: local == true, transcript_events: transcript_events == true, path: path, handler: handler)
      @tab_types[name] = tab_type
      @tab_types_by_id[id] = tab_type
    end

    def register_transport(name, id:, capabilities: nil, execution_profile: nil, path: nil, &handler)
      name = name.to_s
      id = id.to_s
      raise "Plugin transport name is invalid: #{name}" unless name.match?(COMMAND_NAME_PATTERN)
      raise "Plugin transport id is required" if id.empty?
      raise "Plugin transport #{name} requires a handler" unless handler

      if @transports.key?(name) || @transports_by_id.key?(id)
        emit_warning "Warning: skipping duplicate Kward plugin transport #{id}: #{path}"
        return nil
      end

      capabilities = normalize_transport_capabilities(capabilities)
      execution_profile = normalize_execution_profile(execution_profile)
      transport = TransportType.new(id: id, name: name, capabilities: capabilities, execution_profile: execution_profile, path: path, handler: handler)
      @transports[name] = transport
      @transports_by_id[id] = transport
    end

    def register_footer(path: nil, &renderer)
      raise "Plugin footer requires a renderer" unless renderer

      emit_warning "Warning: replacing Kward plugin footer from #{@footer_path}: #{path}" if @footer
      @footer = renderer
      @footer_path = path
    end

    def emit_warning(message)
      @warning_sink ? @warning_sink.call(message) : warn(message)
    end

    def register_transcript_event(path: nil, &handler)
      raise "Plugin transcript event requires a handler" unless handler

      @transcript_event_handlers << { path: path, handler: handler }
    end

    def register_prompt_context(path: nil, &renderer)
      raise "Plugin prompt context requires a renderer" unless renderer

      @prompt_context_renderers << { path: path, renderer: renderer }
    end

    def register_lifecycle(event, host:, path: nil, &handler)
      event = event.to_sym
      raise ArgumentError, "Unknown plugin lifecycle event: #{event}" unless @lifecycle_handlers.key?(event)
      raise ArgumentError, "Plugin lifecycle #{event} requires a handler" unless handler

      @lifecycle_handlers[event] << LifecycleHandler.new(event: event, host: host, path: path, handler: handler)
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

    def transition_lifecycle!(from, to)
      should_run = @lifecycle_mutex.synchronize do
        next false unless @lifecycle_state == from

        @lifecycle_state = to
        true
      end
      yield if should_run
    end

    def stop_lifecycle!(event, timeout:)
      transition_lifecycle!(:active, :stopped) do
        run_lifecycle_callbacks(event)
        @plugins.each_value { |host| host.shutdown(timeout: timeout) }
      end
      self
    end

    def run_lifecycle_callbacks(event)
      @lifecycle_handlers.fetch(event).each do |entry|
        entry.handler.arity.zero? ? entry.handler.call : entry.handler.call(entry.host)
      rescue StandardError => e
        emit_warning "Warning: Kward plugin #{event} error in #{entry.path}: #{e.message}"
      end
    end

    def normalize_tool_schema(name, schema)
      raise ArgumentError, "Plugin tool #{name} schema must be an object" unless schema.is_a?(Hash)

      parameters = schema.each_with_object({}) { |(key, value), result| result[key.to_sym] = DeepCopy.dup(value) }
      type = parameters.fetch(:type, "object").to_s
      raise ArgumentError, "Plugin tool #{name} schema type must be object" unless type == "object"

      properties = parameters.fetch(:properties, {})
      required = parameters.fetch(:required, [])
      raise ArgumentError, "Plugin tool #{name} schema properties must be an object" unless properties.is_a?(Hash)
      raise ArgumentError, "Plugin tool #{name} schema required must be an array" unless required.is_a?(Array)
      if parameters[:additionalProperties] == true
        raise ArgumentError, "Plugin tool #{name} schema cannot allow additional properties"
      end

      property_names = properties.keys.map(&:to_s)
      required = required.map(&:to_s).uniq.sort
      unknown_required = required - property_names
      unless unknown_required.empty?
        raise ArgumentError, "Plugin tool #{name} schema requires unknown properties: #{unknown_required.join(', ')}"
      end

      parameters[:type] = "object"
      parameters[:properties] = properties.keys.sort_by(&:to_s).each_with_object({}) do |key, result|
        result[key] = properties[key]
      end
      parameters[:required] = required
      parameters[:additionalProperties] = false
      DeepCopy.freeze(parameters)
    end

    def normalize_execution_profile(profile)
      return nil if profile.nil?
      return profile if profile.is_a?(Transport::ExecutionProfile)
      raise ArgumentError, "Plugin transport execution_profile must be a Transport::ExecutionProfile"
    end

    def normalize_transport_capabilities(capabilities)
      return Transport.capabilities if capabilities.nil?
      return capabilities if capabilities.is_a?(Transport::Capabilities)
      raise ArgumentError, "Plugin transport capabilities must be a hash or Transport::Capabilities" unless capabilities.is_a?(Hash)

      Transport.capabilities(**capabilities.transform_keys(&:to_sym))
    end

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

    def transcript_event(type, payload = {})
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
  # @param id [String, nil] stable reverse-domain-style plugin identifier
  # @param version [String, nil] plugin release version
  # @param api [String, Integer, nil] Kward plugin API version
  # @yieldparam plugin [PluginRegistry::DSL] plugin registration DSL
  # @return [Object, nil] the plugin block result
  # @api public
  def self.plugin(id: nil, version: nil, api: nil, &block)
    registry = PluginRegistry.loading_registry
    raise "Kward.plugin can only be called while loading a plugin" unless registry

    host = registry.register_plugin_identity(id: id, version: version, api: api, path: PluginRegistry.loading_path)
    dsl = PluginRegistry::DSL.new(registry, PluginRegistry.loading_path, host: host)
    block.arity == 1 ? block.call(dsl) : dsl.instance_eval(&block)
  end
end
