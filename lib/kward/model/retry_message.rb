# Namespace for the Kward CLI agent runtime.
module Kward
  # Formats retry status messages for model-provider requests.
  module RetryMessage
    module_function

    def format(event)
      provider = event.provider.to_s.empty? ? "model" : event.provider
      payload = event.request_bytes ? " with #{event.request_bytes} byte payload" : ""
      "Retrying #{provider} request after transient failure (attempt #{event.attempt}/#{event.max_attempts}) in #{event.delay_seconds}s#{payload}: #{event.error}"
    end
  end
end
