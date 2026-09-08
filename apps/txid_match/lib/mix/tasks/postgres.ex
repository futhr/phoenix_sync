defmodule Mix.Tasks.Txid.Postgres do
  use Mix.Task

  @shortdoc "Manage the pinned PostgreSQL 18.6 development service"

  def run(args) do
    command =
      case args do
        ["up"] -> ["up", "-d", "--wait", "postgres"]
        ["down"] -> ["stop", "postgres"]
        _ -> Mix.raise("Use mix txid.postgres up or mix txid.postgres down")
      end

    compose = Path.expand("../../../../../docker-compose.yml", __DIR__)

    case System.cmd("docker", ["compose", "-f", compose] ++ command,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("PostgreSQL Compose command failed with status #{status}")
    end
  end
end
