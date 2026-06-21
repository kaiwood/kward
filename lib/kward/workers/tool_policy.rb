module Kward
  module Workers
    # Tool allowlists for worker roles.
    module ToolPolicy
      READ_ONLY_TOOLS = %w[list_directory read_file code_search summarize_file_structure retrieve_tool_output web_search fetch_content fetch_raw read_skill].freeze

      module_function

      def allowed_tool_names(role)
        case role.to_s
        when "scout", "read_only"
          READ_ONLY_TOOLS
        else
          nil
        end
      end
    end
  end
end
