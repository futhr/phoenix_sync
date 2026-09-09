defmodule Phoenix.Sync.Adapter do
  @moduledoc false

  @type plug_opts :: keyword() | struct()

  @callback children(atom(), keyword()) :: {:ok, [Supervisor.child_spec()]} | {:error, String.t()}
  @callback plug_opts(atom(), keyword()) :: plug_opts() | no_return()
  @callback client(atom(), keyword()) :: {:ok, struct()} | {:error, String.t()}
end
