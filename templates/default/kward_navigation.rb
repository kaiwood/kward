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
        ["Troubleshooting", "file.troubleshooting.html"]
      ]
    ],
    [
      "Feature guides",
      [
        ["Memory", "file.memory.html"],
        ["Personas", "file.personas.html"],
        ["Extensibility", "file.extensibility.html"],
        ["Plugins", "file.plugins.html"],
        ["Web search", "file.web-search.html"],
        ["Code search", "file.code-search.html"]
      ]
    ],
    [
      "Advanced/reference",
      [
        ["API reference", "file.api.html"],
        ["RPC protocol", "file.rpc.html"],
        ["Releasing", "file.releasing.html"]
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

  def api_groups
    API_GROUPS
  end

  def api_overview
    API_OVERVIEW
  end
end
