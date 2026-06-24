# frozen_string_literal: true

# Space Invaders — a full classic arcade game built as a Kward interactive
# plugin command.
#
# Install: copy this file to ~/.kward/plugins/ and run `/invaders` in the
# Kward TUI.
#
# Controls:
#   ←/→  Move
#   Space  Fire
#   Q / Esc  Quit
#   Ctrl+C  Force quit (handled by Kward)
#
# The game renders colored sprites and particle-burst explosions inside the
# composer canvas region using the interactive mode API.

Kward.plugin do |plugin|
  plugin.interactive_command "invaders", rows: 18, fps: 30, description: "Space Invaders arcade game" do |ui, ctx|
    game = SpaceInvadersGame.new(width: ui.width, height: ui.height)
    ui.on_tick { |ui| game.tick(ui) }
  end
end

# rubocop:disable Metrics/ClassLength, Metrics/MethodLength
class SpaceInvadersGame
  PLAYER_CHAR = "▲"
  PLAYER_COLOR = :cyan
  BULLET_CHAR = "│"
  BULLET_COLOR = :yellow
  BOMB_CHAR = "V"
  BOMB_COLOR = :magenta
  SCORE_LABEL = "Score"
  LIVES_LABEL = "Lives"

  INVADER_ROWS = [
    { char: "M", color: :red,    points: 30 },
    { char: "M", color: :red,    points: 30 },
    { char: "W", color: :yellow, points: 20 },
    { char: "W", color: :yellow, points: 20 },
    { char: "A", color: :green,  points: 10 }
  ].freeze

  PARTICLE_CHARS = %w[* + . o].freeze
  PARTICLE_COLORS = %i[red yellow].freeze
  PARTICLE_LIFE = 6

  MOVE_EVERY = 12
  BULLET_SPEED = 2
  BOMB_SPEED = 1
  MAX_BULLETS = 3
  FIRE_COOLDOWN = 8
  BOMB_CHANCE = 0.015

  def initialize(width:, height:)
    @width = width
    @height = height
    @phase = :playing
    @tick_count = 0
    @score = 0
    @lives = 3
    @wave = 1
    @fire_cooldown = 0
    @invader_dir = 1
    @invaders = []
    @bullets = []
    @bombs = []
    @explosions = []
    @message_timer = 0
    spawn_invaders
    place_player
  end

  def tick(ui)
    drain_keys(ui)
    case @phase
    when :playing
      update_playing
      render_playing(ui)
    when :game_over, :won
      update_message_phase
      render_message(ui)
    end
    ui.render
  end

  private

  def drain_keys(ui)
    while (key = ui.poll_key)
      case key
      when :escape, "q", "Q"
        ui.exit
      when :left
        @player_col -= 1 if @phase == :playing
      when :right
        @player_col += 1 if @phase == :playing
      when :space
        fire_bullet if @phase == :playing
      when :return, :enter
        restart if @phase != :playing
      end
    end
  end

  def place_player
    @player_col = @width / 2
    @player_row = @height - 2
  end

  # ---- Invader spawning ----

  def spawn_invaders
    @invaders = []
    rows = INVADER_ROWS.length
    cols = [(@width - 4) / 4, 6].min
    cols = [cols, 3].max
    start_row = 2
    start_col = (@width - cols * 4) / 2
    start_col = [start_col, 1].max

    rows.times do |row|
      config = INVADER_ROWS[row]
      cols.times do |col|
        @invaders << {
          row: start_row + row,
          col: start_col + col * 4,
          char: config[:char],
          color: config[:color],
          points: config[:points],
          alive: true
        }
      end
    end
    @invader_dir = 1
  end

  # ---- Playing phase updates ----

  def update_playing
    @tick_count += 1
    @fire_cooldown = [@fire_cooldown - 1, 0].max if @fire_cooldown.positive?

    move_invaders if (@tick_count % move_interval).zero?
    move_bullets
    move_bombs
    maybe_drop_bomb
    update_explosions
    check_collisions
    check_win_lose
  end

  def move_interval
    alive = @invaders.count { |inv| inv[:alive] }
    total = @invaders.length
    return MOVE_EVERY if total.zero?

    speedup = ((total - alive) * MOVE_EVERY) / (total * 2)
    [MOVE_EVERY - speedup, 2].max
  end

  def move_invaders
    living = @invaders.select { |inv| inv[:alive] }
    return if living.empty?

    min_col = living.map { |inv| inv[:col] }.min
    max_col = living.map { |inv| inv[:col] }.max

    if @invader_dir.positive? && max_col >= @width - 2
      @invader_dir = -1
      @invaders.each { |inv| inv[:row] += 1 if inv[:alive] }
    elsif @invader_dir.negative? && min_col <= 1
      @invader_dir = 1
      @invaders.each { |inv| inv[:row] += 1 if inv[:alive] }
    else
      @invaders.each { |inv| inv[:col] += @invader_dir if inv[:alive] }
    end
  end

  def fire_bullet
    return if @bullets.length >= MAX_BULLETS
    return if @fire_cooldown.positive?

    @bullets << { row: @player_row - 1, col: @player_col }
    @fire_cooldown = FIRE_COOLDOWN
  end

  def move_bullets
    @bullets.each { |b| b[:row] -= BULLET_SPEED }
    @bullets.reject! { |b| b[:row] < 0 }
  end

  def move_bombs
    @bombs.each { |b| b[:row] += BOMB_SPEED }
    @bombs.reject! { |b| b[:row] >= @height }
  end

  def maybe_drop_bomb
    return if rand > BOMB_CHANCE

    living = @invaders.select { |inv| inv[:alive] }
    return if living.empty?

    # Drop from a random bottom-most invader per column
    columns = living.group_by { |inv| inv[:col] }
    col, invaders = columns.min_by { rand }
    return unless invaders

    bottom = invaders.max_by { |inv| inv[:row] }
    @bombs << { row: bottom[:row] + 1, col: bottom[:col] } if bottom
  end

  # ---- Explosions ----

  def spawn_explosion(row, col, color = :red)
    PARTICLE_LIFE.times do |i|
      angle = (i * 360 / PARTICLE_LIFE) * Math::PI / 180
      dx = (Math.cos(angle) * (i + 1)).round
      dy = (Math.sin(angle) * (i + 1)).round
      @explosions << {
        row: row + dy,
        col: col + dx,
        char: PARTICLE_CHARS[i % PARTICLE_CHARS.length],
        color: PARTICLE_COLORS[i % PARTICLE_COLORS.length],
        life: PARTICLE_LIFE
      }
    end
  end

  def update_explosions
    @explosions.each { |e| e[:life] -= 1 }
    @explosions.reject! { |e| e[:life] <= 0 }
  end

  # ---- Collisions ----

  def check_collisions
    check_bullet_invader_hits
    check_bomb_player_hits
  end

  def check_bullet_invader_hits
    @bullets.reject! do |bullet|
      hit = @invaders.find { |inv| inv[:alive] && inv[:row] == bullet[:row] && inv[:col] == bullet[:col] }
      next false unless hit

      hit[:alive] = false
      @score += hit[:points]
      spawn_explosion(hit[:row], hit[:col], hit[:color])
      true
    end
  end

  def check_bomb_player_hits
    @bombs.reject! do |bomb|
      hit = bomb[:row] == @player_row && bomb[:col] == @player_col
      next false unless hit

      @lives -= 1
      spawn_explosion(@player_row, @player_col, :cyan)
      @phase = :game_over if @lives <= 0
      true
    end
  end

  def check_win_lose
    return unless @phase == :playing

    @phase = :won if @invaders.none? { |inv| inv[:alive] }

    return unless @invaders.any? { |inv| inv[:alive] && inv[:row] >= @player_row }

    @phase = :game_over
    spawn_explosion(@player_row, @player_col, :cyan)
  end

  # ---- Message phase ----

  def update_message_phase
    @message_timer += 1
  end

  def restart
    @score = 0
    @lives = 3
    @wave = 1
    @tick_count = 0
    @bullets.clear
    @bombs.clear
    @explosions.clear
    @fire_cooldown = 0
    @invader_dir = 1
    spawn_invaders
    place_player
    @phase = :playing
    @message_timer = 0
  end

  # ---- Rendering ----

  def render_playing(ui)
    ui.clear_frame

    render_hud(ui)
    render_invaders(ui)
    render_bullets(ui)
    render_bombs(ui)
    render_explosions(ui)
    ui.put(@player_row, @player_col, PLAYER_CHAR, PLAYER_COLOR)
  end

  def render_hud(ui)
    score_text = "#{SCORE_LABEL}: #{@score}"
    lives_text = "#{LIVES_LABEL}: #{@lives}"
    wave_text = "Wave: #{@wave}"

    score_text.chars.each_with_index do |char, i|
      ui.put(0, i, char, :green)
    end
    lives_col = @width - lives_text.length
    lives_text.chars.each_with_index do |char, i|
      ui.put(0, lives_col + i, char, :cyan)
    end
    wave_col = (@width - wave_text.length) / 2
    wave_text.chars.each_with_index do |char, i|
      ui.put(0, wave_col + i, char, :gray)
    end
  end

  def render_invaders(ui)
    @invaders.each do |inv|
      next unless inv[:alive]

      ui.put(inv[:row], inv[:col], inv[:char], inv[:color])
    end
  end

  def render_bullets(ui)
    @bullets.each { |b| ui.put(b[:row], b[:col], BULLET_CHAR, BULLET_COLOR) }
  end

  def render_bombs(ui)
    @bombs.each { |b| ui.put(b[:row], b[:col], BOMB_CHAR, BOMB_COLOR) }
  end

  def render_explosions(ui)
    @explosions.each do |e|
      ui.put(e[:row], e[:col], e[:char], e[:color])
    end
  end

  def render_message(ui)
    ui.clear_frame
    render_invaders(ui)
    render_explosions(ui)

    if @phase == :won
      message = "YOU WIN!"
      color = :green
    else
      message = "GAME OVER"
      color = :red
    end

    center_text(ui, @height / 2, message, color)
    center_text(ui, @height / 2 + 2, "Score: #{@score}", :yellow)
    center_text(ui, @height / 2 + 4, "Enter: restart  Q: quit", :gray)
  end

  def center_text(ui, row, text, color)
    col = (@width - text.length) / 2
    text.chars.each_with_index do |char, i|
      ui.put(row, col + i, char, color)
    end
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/MethodLength
