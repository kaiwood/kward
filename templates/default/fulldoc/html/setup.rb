# frozen_string_literal: true

def generate_assets
  super
  asset('css/kward.css', file('css/kward.css', true))
  asset('js/kward.js', file('js/kward.js', true))
  asset('images/kward_logo.png', file('images/kward_logo.png', true))
end
