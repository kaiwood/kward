if __FILE__ == $PROGRAM_NAME
  require_relative "kward/entrypoint"
  Kward::Entrypoint.run
else
  require_relative "kward/cli"
end
