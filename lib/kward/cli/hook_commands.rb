require "json"
require "uri"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive lifecycle hook inspection commands.
    module HookCommands
      private

      def handle_hooks_command(argument)
        subcommand, rest = argument.to_s.strip.split(/\s+/, 2)
        subcommand = "list" if subcommand.to_s.empty?

        case subcommand
        when "list"
          print_hooks_list
        when "events"
          print_hooks_events
        when "logs"
          print_hooks_logs(rest)
        when "doctor"
          print_hooks_doctor
        when "trust"
          trust_workspace_hooks
        when "untrust"
          untrust_workspace_hooks
        else
          runtime_output("Usage: /hooks [list|events|logs|doctor|trust|untrust]")
        end
      end

      def print_hooks_list
        lines = ["Lifecycle hooks"]
        entries = configured_hook_entries + workspace_hook_entries + plugin_hook_entries
        if entries.empty?
          lines << "No lifecycle hooks are configured."
        else
          entries.each do |entry|
            details = [entry.fetch(:id), entry.fetch(:event)]
            details << "source=#{entry.fetch(:source)}"
            details << "order=#{entry.fetch(:order)}"
            details << "failure_policy=#{entry[:failure_policy]}" if entry[:failure_policy]
            details << "disabled" if entry[:disabled]
            lines << "- #{details.join(' ')}"
          end
        end
        runtime_output(lines.join("\n"))
      end

      def print_hooks_events
        lines = ["Lifecycle hook events"]
        Hooks::Catalog.event_names.each do |event_name|
          definition = Hooks::Catalog.definition(event_name)
          fields = Array(definition&.modifiable_fields)
          suffix = fields.empty? ? "" : " modifies=#{fields.join(',')}"
          lines << "- #{event_name} failure_policy=#{Hooks::Catalog.failure_policy(event_name)}#{suffix}"
        end
        runtime_output(lines.join("\n"))
      end

      def print_hooks_logs(argument)
        count = argument.to_s.strip.empty? ? 20 : argument.to_i
        count = 20 unless count.positive?
        path = hooks_log_path
        unless File.file?(path)
          runtime_output("No lifecycle hook audit log found at #{path}.")
          return
        end

        records = File.readlines(path, chomp: true).last(count).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        if records.empty?
          runtime_output("No readable lifecycle hook audit records found at #{path}.")
          return
        end

        lines = ["Lifecycle hook audit log: #{path}"]
        records.each do |record|
          lines << format_hook_log_record(record)
        end
        runtime_output(lines.join("\n"))
      end

      def print_hooks_doctor
        lines = ["Lifecycle hook diagnostics"]
        begin
          diagnostics = hook_config_diagnostics(ConfigFiles.read_config, "config") + hook_config_diagnostics(ConfigFiles.read_trusted_workspace_hooks_config(current_workspace_root), "workspace")
          manager = diagnostics.empty? ? Hooks::ConfigLoader.new(ConfigFiles.lifecycle_hooks_config(current_workspace_root)).manager : nil
          lines << "Config and trusted workspace hooks: #{manager ? manager.handlers.length : "not loaded due diagnostics"}"
          lines << "Plugin hooks: #{plugin_registry.hook_handlers.length}"
          lines << "Audit log: #{hooks_log_path}"
          lines << "Workspace hook config: #{ConfigFiles.workspace_hooks_path(current_workspace_root)}"
          lines << "Workspace hooks trusted: #{ConfigFiles.workspace_hooks_trusted?(current_workspace_root)}"
          lines << "Known events: #{Hooks::Catalog.event_names.length}"
          if diagnostics.empty?
            lines << "OK"
          else
            lines.concat(diagnostics.map { |diagnostic| "Warning: #{diagnostic}" })
          end
        rescue StandardError => e
          lines << "Error: #{e.message}"
        end
        runtime_output(lines.join("\n"))
      end

      def configured_hook_entries
        hook_entries_from_config(ConfigFiles.read_config, "config")
      end

      def workspace_hook_entries
        hook_entries_from_config(ConfigFiles.read_trusted_workspace_hooks_config(current_workspace_root), "workspace")
      end

      def plugin_hook_entries
        plugin_registry.hook_handlers.map do |hook|
          {
            id: hook.id,
            event: hook.event,
            source: hook.path || "plugin",
            order: hook.order,
            failure_policy: hook.failure_policy,
            disabled: false
          }
        end
      end

      def hook_entries_from_config(config, source)
        hooks = config["hooks"] || config[:hooks]
        return [] unless hooks.is_a?(Hash)

        hooks.flat_map do |event, entries|
          Array(entries).each_with_index.map do |entry, index|
            entry = entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : { "command" => entry.to_s }
            {
              id: entry["id"] || "#{source}:#{event}:#{index + 1}",
              event: event.to_s,
              source: source,
              order: entry.fetch("order", 100),
              failure_policy: entry["failure_policy"],
              disabled: truthy_hook_value?(entry["disabled"])
            }
          end
        end
      end

      def hook_config_diagnostics(config, source)
        hooks = config["hooks"] || config[:hooks]
        return [] unless hooks.is_a?(Hash)

        hooks.flat_map do |event, entries|
          Array(entries).each_with_index.flat_map do |entry, index|
            validate_hook_entry(event.to_s, normalize_hook_entry(entry), source, index + 1)
          end
        end
      end

      def normalize_hook_entry(entry)
        entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : { "type" => "command", "command" => entry.to_s }
      end

      def validate_hook_entry(event, entry, source, number)
        label = entry["id"] || "#{source}:#{event}:#{number}"
        diagnostics = []
        diagnostics << "#{label}: unknown event #{event}" unless Hooks::Catalog.known?(event)
        diagnostics.concat(validate_hook_failure_policy(label, entry))
        diagnostics.concat(validate_hook_timeout(label, entry))
        diagnostics.concat(validate_hook_type(label, entry))
        diagnostics
      end

      def validate_hook_failure_policy(label, entry)
        policy = entry["failure_policy"]
        return [] if policy.to_s.empty? || Hooks::Catalog::VALID_FAILURE_POLICIES.include?(policy.to_s)

        ["#{label}: unknown failure_policy #{policy}"]
      end

      def validate_hook_timeout(label, entry)
        value = entry["timeout_seconds"]
        return [] if value.nil? || value.to_f.positive?

        ["#{label}: timeout_seconds must be positive"]
      end

      def validate_hook_type(label, entry)
        type = (entry["type"] || "command").to_s
        case type
        when "command"
          validate_command_hook(label, entry)
        when "http"
          validate_http_hook(label, entry)
        else
          ["#{label}: unsupported hook type #{type}"]
        end
      end

      def validate_command_hook(label, entry)
        command = entry["command"].to_s.strip
        return ["#{label}: command is required"] if command.empty?

        executable = command.split(/\s+/, 2).first
        return [] if executable.include?(File::SEPARATOR) ? File.executable?(File.expand_path(executable)) : system_command_available?(executable)

        ["#{label}: command executable not found: #{executable}"]
      end

      def validate_http_hook(label, entry)
        uri = URI.parse(entry["url"].to_s)
        return [] if %w[http https].include?(uri.scheme) && uri.host

        ["#{label}: url must be http or https"]
      rescue URI::InvalidURIError
        ["#{label}: url must be http or https"]
      end

      def system_command_available?(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, name))
        end
      end

      def trust_workspace_hooks
        ConfigFiles.trust_workspace_hooks!(current_workspace_root)
        runtime_output("Trusted workspace hooks: #{ConfigFiles.workspace_hooks_path(current_workspace_root)}")
      rescue StandardError => e
        runtime_output("Workspace hook trust error: #{e.message}")
      end

      def untrust_workspace_hooks
        ConfigFiles.untrust_workspace_hooks!(current_workspace_root)
        runtime_output("Untrusted workspace hooks: #{ConfigFiles.workspace_hooks_path(current_workspace_root)}")
      rescue StandardError => e
        runtime_output("Workspace hook trust error: #{e.message}")
      end

      def hooks_log_path
        File.join(ConfigFiles.config_dir, "logs", "hooks.jsonl")
      end

      def format_hook_log_record(record)
        parts = [record["timestamp"], record["kind"], record["event"]].compact
        parts << "hook=#{record['hook_id']}" if record["hook_id"]
        parts << "decision=#{record['decision']}" if record["decision"]
        parts << record["message"] if record["message"]
        "- #{parts.join(' ')}"
      end

      def truthy_hook_value?(value)
        value == true || value.to_s == "true"
      end
    end
  end
end
