import Config

config :phoenix_sync, mode: :sandbox, env: config_env()

config :plug_sync, ecto_repos: [PlugSync.Repo]

config :plug_sync, PlugSync.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "password"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "plug_sync_test",
  port: String.to_integer(System.get_env("PGPORT", "55555")),
  pool: Ecto.Adapters.SQL.Sandbox
