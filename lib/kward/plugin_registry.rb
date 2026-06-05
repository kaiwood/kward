require_relative "config_files"

module Kward
  class PluginRegistry
    COMMAND_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.freeze

    Command = Struct.new(:name, :description, :argument_hint, :path, :handler, keyword_init: true) do
      def entry
        { name: name, description: description, argument_hint: argument_hint }
      end
    end

    class Transcript
      def initialize(conversation)
        @conversation = conversation
      end

      def messages
        PluginRegistry.deep_freeze(PluginRegistry.deep_dup(@conversation.messages))
      end
    end

    class Context
      attr_reader :args, :workspace_root

      def initialize(conversation:, args: "", session: nil, workspace_root: Dir.pwd, say_callback: nil)
        @conversation = conversation
        @args = args.to_s
        @session = session
        @workspace_root = workspace_root
        @say_callback = say_callback
      end

      def transcript
        Transcript.new(@conversation)
      end

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
    end

    class DSL
      def initialize(registry, path)
        @registry = registry
        @path = path
      end

      def command(name, description: "", argument_hint: "", &block)
        @registry.register_command(name, description: description, argument_hint: argument_hint, path: @path, &block)
      end

      def footer(&block)
        @registry.register_footer(path: @path, &block)
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
  end

  def self.plugin(&block)
    registry = PluginRegistry.loading_registry
    raise "Kward.plugin can only be called while loading a plugin" unless registry

    dsl = PluginRegistry::DSL.new(registry, PluginRegistry.loading_path)
    block.arity == 1 ? block.call(dsl) : dsl.instance_eval(&block)
  end
end
