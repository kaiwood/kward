require_relative "telegram_transport"

Kward.plugin do |plugin|
  plugin.transport(
    "telegram",
    id: "com.kward.telegram",
    capabilities: {
      inbound: %i[text],
      outbound: %i[text],
      streaming: :aggregate,
      limits: { message_length: Kward::Telegram::Transport::TELEGRAM_MESSAGE_LIMIT }
    }
  ) do |host, config|
    Kward::Telegram::Transport.new(host: host, config: config)
  end
end
