# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # User-facing default status text for editor buffers.
    module EditorStatusText
      module_function

      def default(readonly:, editor_mode:)
        return "Read-only diff · arrows/PageUp/PageDown move · Ctrl+F search · Ctrl+Q close" if readonly

        case editor_mode
        when "emacs"
          "C-x C-s save · C-x C-c quit · C-s search"
        when "vibe"
          "NORMAL · i insert · :w save · :q quit"
        else
          "Ctrl+S save · Ctrl+Q quit · Ctrl+F search · Ctrl+C copy"
        end
      end
    end
  end
end
