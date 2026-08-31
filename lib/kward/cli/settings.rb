require_relative "settings/menus"
require_relative "settings/model"

# CLI settings facade retaining the original include surface.
module Kward
  class CLI
    module Settings
      include Menus
      include Model
    end
  end
end
