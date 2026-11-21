require_relative "base"
require_relative "../model/codex_images"
require_relative "../generated_images"

module Kward
  module Tools
    # Generates a preview, never a workspace file. The frontend owns export.
    class GenerateImage < Base
      NAME = "generate_image".freeze
      MAX_PROMPT_BYTES = 16_384

      def initialize(client:, images:)
        super(NAME, "Generate one PNG when the user asks to create an image. Describe what to draw, not a destination. Kward presents the preview and the user decides whether and where to save it.",
              properties: { "prompt" => { type: "string", description: "What to draw." } }, required: ["prompt"])
        @client = client
        @images = images
      end

      def call(args, conversation, cancellation: nil, provider: nil, turn_id: nil)
        prompt = args["prompt"] || args[:prompt]
        unless prompt.is_a?(String) && !prompt.strip.empty? && prompt.bytesize <= MAX_PROMPT_BYTES
          return "Error: provide a non-empty image prompt of at most #{MAX_PROMPT_BYTES} bytes."
        end
        return "Error: image generation requires a Codex turn." unless provider == "Codex"

        bytes = @client.generate_codex_image(prompt, turn_id: turn_id, cancellation: cancellation)
        cancellation&.raise_if_cancelled!
        image = @images.add(conversation, bytes, cancellation: cancellation)
        yield image if block_given?
        "Image generated. The preview is ready for the user to save or discard. No project file was written."
      rescue CodexImages::Error, GeneratedImages::Error => e
        "Error: #{e.message}"
      end
    end
  end
end
