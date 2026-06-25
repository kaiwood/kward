# frozen_string_literal: true

require "json"
require_relative "../../kward_navigation"

module KwardDocsNavigation
  include KwardDocsNavigationData
  API_FILE_LINKS = {
    "doc/api.md" => API_OVERVIEW
  }.freeze
  API_LINKS = ([API_OVERVIEW] + API_GROUPS.flat_map { |_title, items| items.map(&:last) }).freeze

  EXTENSION_OVERVIEW = "file.extensibility.html"
  EXTENSION_LINKS = ([EXTENSION_OVERVIEW] + EXTENSION_GROUPS.flat_map { |_title, items| items.map(&:last) }).uniq.freeze

  GUIDE_OVERVIEW = "file.README.html"
  GUIDE_LINKS = ([GUIDE_OVERVIEW] + GUIDE_GROUPS.flat_map { |_title, items| items.map(&:last) }).freeze
  GUIDE_SEARCH_FILES = [
    ["Overview", "README.md", GUIDE_OVERVIEW],
    *(GUIDE_GROUPS + EXTENSION_GROUPS).flat_map do |_title, items|
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
    "doc/session-management.md" => "file.session-management.html",
    "doc/editor.md" => "file.editor.html",
    "doc/git.md" => "file.git.html",
    "doc/memory.md" => "file.memory.html",
    "doc/personas.md" => "file.personas.html",
    "doc/extensibility.md" => "file.extensibility.html",
    "doc/plugins.md" => "file.plugins.html",
    "doc/agent-tools.md" => "file.agent-tools.html",
    "doc/workspace-tools.md" => "file.workspace-tools.html",
    "doc/web-search.md" => "file.web-search.html",
    "doc/code-search.md" => "file.code-search.html",
    "doc/context-tools.md" => "file.context-tools.html",
    "doc/rpc.md" => "file.rpc.html",
    "doc/releasing.md" => "file.releasing.html"
  }.freeze

  def guide_overview
    GUIDE_OVERVIEW
  end

  def extension_overview
    EXTENSION_OVERVIEW
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
    defined?(@file) && GUIDE_LINKS.include?(GUIDE_FILE_LINKS[@file&.filename.to_s])
  end

  def extension_file?
    defined?(@file) && EXTENSION_LINKS.include?(GUIDE_FILE_LINKS[@file&.filename.to_s])
  end

  def api_file?
    defined?(@file) && API_FILE_LINKS.key?(@file&.filename.to_s)
  end

  def home_page?
    options.index && readme_file?
  end

  def guide_page?
    (readme_file? && !options.index) || guide_file? || GUIDE_LINKS.include?(current_docs_path)
  end

  def extension_page?
    extension_file? || EXTENSION_LINKS.include?(current_docs_path)
  end

  def api_page?
    api_file? || API_LINKS.include?(current_docs_path) || (!home_page? && !guide_page? && !extension_page?)
  end

  def diskfile
    @file.attributes[:markup] ||= markup_for_file('', @file.filename)
    data = rewrite_guide_links(htmlify(@file.contents, @file.attributes[:markup]))
    "<div id='filecontents'>" + data + "</div>"
  end

  def rewrite_guide_links(html)
    GUIDE_FILE_LINKS.merge(API_FILE_LINKS).each do |source, target|
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
