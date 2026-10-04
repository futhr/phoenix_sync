defmodule Phoenix.Sync.Electric.ResponseCleanupTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Electric.Shapes.Api
  alias Electric.Shapes.Api.Response

  test "discarding an unsent snapshot halts its body and releases the registered reader" do
    stack_id = "response-cleanup-test"
    registry = Electric.StackSupervisor.registry_name(stack_id)
    start_supervised!({Registry, keys: :duplicate, name: registry})
    Registry.register(registry, "owned-shape", nil)
    owner = self()

    body =
      Stream.resource(
        fn ->
          send(owner, :body_started)
          0
        end,
        fn index ->
          send(owner, {:body_chunk, index})
          {["private row #{index}"], index + 1}
        end,
        fn _ -> send(owner, :body_closed) end
      )

    response =
      %Response{api: %Api{stack_id: stack_id}, handle: "owned-shape", chunked: true, body: body}
      |> Response.ensure_cleanup()

    conn = Plug.Conn.assign(Plug.Test.conn(:get, "/shape"), :response, response)

    assert :ok = Phoenix.Sync.Electric.discard_response_stream(conn)
    assert_receive :body_started
    assert_receive {:body_chunk, 0}
    assert_receive :body_closed
    refute_receive {:body_chunk, 1}
    assert Registry.lookup(registry, "owned-shape") == []
    assert conn.state == :unset
  end

  test "responses already consumed by the long-poll owner need no stream cleanup" do
    response = %Response{chunked: false, body: ["already consumed"]}
    conn = Plug.Conn.assign(Plug.Test.conn(:get, "/shape"), :response, response)

    assert :ok = Phoenix.Sync.Electric.discard_response_stream(conn)
    assert :ok = Phoenix.Sync.Electric.discard_response_stream(Plug.Test.conn(:get, "/shape"))
  end
end
