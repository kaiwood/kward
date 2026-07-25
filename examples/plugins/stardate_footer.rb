# Displays the current Federation stardate in Kward's interactive footer.
Kward.plugin do |plugin|
  plugin.footer do |_ctx|
    now = Time.now.utc
    reference = Time.utc(1987, 7, 15)
    stardate = 41_000 + ((now - reference) / (365.25 * 24 * 60 * 60) * 1_000)

    "Stardate: #{format('%.1f', stardate)}"
  end
end
