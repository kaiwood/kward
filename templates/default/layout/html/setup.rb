# frozen_string_literal: true

require "json"

module KwardDocsNavigation
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
        ["RPC protocol", "file.rpc.html"],
        ["Releasing", "file.releasing.html"]
      ]
    ]
  ].freeze

  GUIDE_OVERVIEW = "file.README.html"
  GUIDE_LINKS = ([GUIDE_OVERVIEW] + GUIDE_GROUPS.flat_map { |_title, items| items.map(&:last) }).freeze
  GUIDE_SEARCH_FILES = [
    ["Overview", "README.md", GUIDE_OVERVIEW],
    *GUIDE_GROUPS.flat_map do |_title, items|
      items.map do |label, link|
        source = "doc/#{link.delete_prefix("file.").delete_suffix(".html")}.md"
        [label, source, link]
      end
    end
  ].freeze
  GUIDE_FILE_LINKS = {
    "doc/getting-started.md" => "file.getting-started.html",
    "doc/usage.md" => "file.usage.html",
    "doc/configuration.md" => "file.configuration.html",
    "doc/authentication.md" => "file.authentication.html",
    "doc/troubleshooting.md" => "file.troubleshooting.html",
    "doc/memory.md" => "file.memory.html",
    "doc/personas.md" => "file.personas.html",
    "doc/extensibility.md" => "file.extensibility.html",
    "doc/plugins.md" => "file.plugins.html",
    "doc/web-search.md" => "file.web-search.html",
    "doc/code-search.md" => "file.code-search.html",
    "doc/rpc.md" => "file.rpc.html",
    "doc/releasing.md" => "file.releasing.html"
  }.freeze

  def guide_groups
    GUIDE_GROUPS
  end

  def guide_overview
    GUIDE_OVERVIEW
  end

  def guide_search_index_json
    JSON.generate(guide_search_index).gsub("</", "<\\/")
  end

  def guide_search_index
    GUIDE_SEARCH_FILES.filter_map do |title, source, link|
      next unless File.file?(source)

      content = File.read(source)
      {
        title: title,
        path: source,
        url: url_for(link),
        text: content.gsub(/[`*_#>\[\]()]/, " ").gsub(/\s+/, " ").strip
      }
    end
  end

  def current_docs_path
    serializer = options.serializer
    return "index.html" unless serializer

    File.basename(serializer.serialized_path(object))
  end

  def readme_file?
    defined?(@file) && @file&.name == "README"
  end

  def guide_file?
    defined?(@file) && GUIDE_FILE_LINKS.key?(@file&.filename.to_s)
  end

  def home_page?
    options.index && readme_file?
  end

  def guide_page?
    (readme_file? && !options.index) || guide_file? || GUIDE_LINKS.include?(current_docs_path)
  end

  def api_page?
    !home_page? && !guide_page?
  end

  def diskfile
    @file.attributes[:markup] ||= markup_for_file('', @file.filename)
    data = rewrite_guide_links(htmlify(@file.contents, @file.attributes[:markup]))
    "<div id='filecontents'>" + data + "</div>"
  end

  def rewrite_guide_links(html)
    GUIDE_FILE_LINKS.each do |source, target|
      html = html.gsub(%(href="#{source}"), %(href="#{target}"))
    end
    html
  end
end

include KwardDocsNavigation

def javascripts
  super
end

def stylesheets
  super + %w(css/kward.css)
end
