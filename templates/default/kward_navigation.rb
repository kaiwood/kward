# frozen_string_literal: true

module KwardDocsNavigationData
  GUIDE_GROUPS = [
    [
      "Start here",
      [
        ["Getting started", "file.getting-started.html"],
        ["Usage", "file.usage.html"],
        ["Configuration", "file.configuration.html"],
        ["Authentication", "file.authentication.html"],
        ["Security and trust", "file.security.html"],
        ["Troubleshooting", "file.troubleshooting.html"]
      ]
    ],
    [
      "Feature guides",
      [
        ["Sessions", "file.session-management.html"],
        ["Tabs", "file.tabs.html"],
        ["Memory", "file.memory.html"],
        ["Personas", "file.personas.html"],
        ["Skills", "file.skills.html"],
        ["Pan mode", "file.pan.html"]
      ]
    ],
    [
      "User Tools",
      [
        ["Project files", "file.files.html"],
        ["Integrated Editor", "file.editor.html"],
        ["Git", "file.git.html"],
        ["Shell", "file.shell.html"]
      ]
    ]
  ].freeze

  EXTENSION_GROUPS = [
    [
      "Customize",
      [
        ["Extensibility", "file.extensibility.html"],
        ["Plugins", "file.plugins.html"],
        ["Lifecycle hooks", "file.lifecycle-hooks.html"]
      ]
    ],
    [
      "Integrate",
      [
        ["MCP servers", "file.mcp.html"],
        ["RPC protocol", "file.rpc.html"],
        ["Releasing", "file.releasing.html"]
      ]
    ],
    [
      "Agent tools",
      [
        ["Overview", "file.agent-tools.html"],
        ["Workspace tools", "file.workspace-tools.html"],
        ["Web search", "file.web-search.html"],
        ["Code search", "file.code-search.html"],
        ["Context tools", "file.context-tools.html"],
        ["Context budgeting", "file.context-budgeting.html"]
      ]
    ]
  ].freeze

  API_OVERVIEW = "file.api.html"
  API_GROUPS = [
    [
      "Reference",
      [
        ["Overview", API_OVERVIEW],
        ["Classes & Modules", "class_list.html"],
        ["Methods", "method_list.html"],
        ["Files", "file_list.html"]
      ]
    ],
    [
      "Key namespaces",
      [
        ["Kward", "Kward.html"],
        ["Tools", "Kward/Tools.html"],
        ["RPC", "Kward/RPC.html"],
        ["CLI", "Kward/CLI.html"],
        ["Prompts", "Kward/Prompts.html"],
        ["Skills", "Kward/Skills.html"]
      ]
    ]
  ].freeze

  def guide_groups
    GUIDE_GROUPS
  end

  def extension_groups
    EXTENSION_GROUPS
  end

  def api_groups
    API_GROUPS
  end

  def api_overview
    API_OVERVIEW
  end
end
