# Displays the current Federation stardate in Kward's interactive footer.
Kward.plugin(id: "com.kward.example.stardate-footer", version: "1.0.0", api: 1) do |plugin|
  plugin.status "stardate", priority: :low do |_ctx|
    now = Time.now.utc
    reference = Time.utc(1987, 7, 15)
    stardate = 41_000 + ((now - reference) / (365.25 * 24 * 60 * 60) * 1_000)

    "Stardate: #{format('%.1f', stardate)}"
  end
end
