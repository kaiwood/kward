# frozen_string_literal: true

require_relative "../../kward_navigation"

include KwardDocsNavigationData

def generate_assets
  super
  asset('css/kward.css', file('css/kward.css', true))
  asset('js/kward.js', file('js/kward.js', true))
  asset('images/kward_logo.png', file('images/kward_logo.png', true))
  asset('images/kward_screen_1.png', file('images/kward_screen_1.png', true))
end

def stylesheets_full_list
  super + %w(css/kward.css)
end
