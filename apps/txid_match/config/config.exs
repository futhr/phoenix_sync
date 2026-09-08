import Config

connection_opts = [
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "password"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: System.get_env("PGDATABASE", "phoenix_sync"),
  port: String.to_integer(System.get_env("PGPORT", "55555"))
]

config :txid_match, Postgrex, connection_opts

config :phoenix_sync,
  env: config_env(),
  mode: :embedded,
  connection_opts: [{:sslmode, :disable} | connection_opts]
