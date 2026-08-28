require_relative "../config_files"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Prompt-template and slash-command parsing helpers.
  module PromptCommands
    BUILTIN_COMMANDS = [
      { name: "exit", description: "Exit the interactive session.", argument_hint: "" },
      { name: "quit", description: "Exit the interactive session.", argument_hint: "" },
      { name: "new", description: "Start a new session.", argument_hint: "" },
      { name: "session", description: "Open saved sessions or name the current session.", argument_hint: "[path]|name [name]" },
      { name: "resume", description: "Alias for /session.", argument_hint: "[path]" },
      { name: "rename", description: "Rename the current session.", argument_hint: "<name>" },
      { name: "clone", description: "Clone the current session.", argument_hint: "" },
      { name: "fork", description: "Fork from an earlier prompt into a new session.", argument_hint: "" },
      { name: "rewind", description: "Revisit an earlier prompt and try a different direction.", argument_hint: "" },
      { name: "tree", description: "Inspect and navigate the full technical session tree.", argument_hint: "" },
      { name: "copy", description: "Copy clean session text to the clipboard.", argument_hint: "[last|transcript]" },
      { name: "export", description: "Export the current session as Markdown.", argument_hint: "[path]" },
      { name: "compact", description: "Compact the current conversation context.", argument_hint: "[instructions]" },
      { name: "redraw", description: "Refresh the visible terminal.", argument_hint: "" },
      { name: "settings", description: "Configure Kward interactively.", argument_hint: "" },
      { name: "login", description: "Log in with an OAuth provider.", argument_hint: "" },
      { name: "model", description: "Select the default model.", argument_hint: "" },
      { name: "reasoning", description: "Select reasoning effort.", argument_hint: "" },
      { name: "reload", description: "Reload installed plugins.", argument_hint: "" },
      { name: "git", description: "Review uncommitted changes and commit them.", argument_hint: "" },
      { name: "diff", description: "Open the file changes recorded in this session.", argument_hint: "" },
      { name: "files", description: "Browse project files.", argument_hint: "" },
      { name: "shell", description: "Open the embedded Kward shell.", argument_hint: "" },
      { name: "capture", description: "Run a command with bounded transcript capture.", argument_hint: "<command>" },
      { name: "scratchpad", description: "Open an unsaved editor buffer.", argument_hint: "[language|help]" },
      { name: "pty", description: "Run a command in an interactive PTY passthrough session.", argument_hint: "<command>" },
      { name: "tab", description: "Manage tabs.", argument_hint: "[1-n|move|close|new|name|worktree]" },
      { name: "worktree", description: "Manage the active tab's linked Git worktree.", argument_hint: "[activate|detach|status|merge|merge abort|remove]" },
      { name: "status", description: "Show the current status message.", argument_hint: "" },
      { name: "stats", description: "Show telemetry logging stats.", argument_hint: "[range]" },
      { name: "sandbox", description: "Inspect or configure model command sandboxing.", argument_hint: "[status|off|read_only|workspace_write|network allow|network deny]" },
      { name: "hooks", description: "Inspect lifecycle hooks.", argument_hint: "[list|events|logs|doctor|trust|untrust]" },
      { name: "skill", description: "Activate a skill or capture one from a saved session.", argument_hint: "<name>|capture" },
      { name: "skills", description: "Review project skill trust.", argument_hint: "[status|trust|untrust]" },
      { name: "memory", description: "Inspect and manage Kward memory.", argument_hint: "[enable|disable|auto-summary|core|add|list|forget|promote|relax|inspect|why|summarize]" }
    ].freeze
    BUILTIN_RESERVED_COMMAND_NAMES = BUILTIN_COMMANDS.map { |command| command[:name] }.freeze
    SLASH_COMMAND_PATTERN = %r{\A/(\S+)(?:\s+(.*))?\z}m

    module_function

    def parse(input)
      match = input.to_s.match(SLASH_COMMAND_PATTERN)
      return nil unless match

      [match[1], match[2].to_s]
    end

    def expand(input, templates: nil, reserved_commands: BUILTIN_RESERVED_COMMAND_NAMES)
      parsed = parse(input)
      return nil unless parsed

      command, arguments = parsed
      templates ||= ConfigFiles.prompt_templates(reserved_commands: reserved_commands)
      template = templates.find { |candidate| candidate.command == command }
      return nil unless template

      template.expand(arguments)
    end
  end
end
