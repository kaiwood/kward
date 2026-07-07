require "json"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Parses and filters GitHub Copilot model catalog responses.
  module CopilotModels
    module_function

    def parse(body)
      catalog_entries(body).filter_map { |entry| model_id(entry) }.uniq
    rescue JSON::ParserError
      []
    end

    def supported?(model)
      text = model.to_s
      text.match?(/\Agpt-5(?:\.|-|\z)/) || text.match?(/\A(?:gemini-|gpt-4\.1|oswe-)/)
    end

    def catalog_entries(body)
      data = JSON.parse(body.to_s)
      entries = data.is_a?(Hash) ? data["data"] || data["models"] || data["items"] || [] : data
      Array(entries)
    end

    def model_id(entry)
      return entry.to_s.strip unless entry.is_a?(Hash)
      return nil if entry.key?("model_picker_enabled") && entry["model_picker_enabled"] == false

      id = entry["id"] || entry["model"] || entry["name"]
      id.to_s.strip unless id.to_s.strip.empty?
    end
  end
end
