defmodule Phoenix.Sync.Electric.ClientAdapterTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Plug.Test

  alias Phoenix.Sync.Electric.ClientAdapter

  defmodule MockFetch do
    @moduledoc false

    def validate_opts(opts), do: {:ok, opts}

    def fetch(request, parent: parent) do
      send(parent, {:fetch_request, request})

      %Electric.Client.Fetch.Response{
        status: 200,
        headers: %{},
        body: ["[]"]
      }
    end
  end

  defmodule TransportErrorFetch do
    @moduledoc false

    def validate_opts(opts), do: {:ok, opts}
    def fetch(_request, _opts), do: {:error, :pool_not_available}
  end

  defmodule ResponseFetch do
    @moduledoc false

    def validate_opts(opts), do: {:ok, opts}
    def fetch(_request, response: response), do: response
  end

  test "decoded snapshot and refetch bodies are encoded as JSON on the wire" do
    for {status, body} <- [
          {200, [%{"key" => "row-1", "headers" => %{}, "value" => %{"label" => "Private"}}]},
          {200, []},
          {400, %{"message" => "Invalid request"}},
          {409, [%{"headers" => %{"control" => "must-refetch"}}]}
        ] do
      conn = deliver(%Electric.Client.Fetch.Response{status: status, body: body})

      assert conn.status == status
      assert Jason.decode!(conn.resp_body) == body
    end
  end

  test "raw binary and iodata responses keep their existing encoding" do
    for body <- ["[]", ["[]"], ""] do
      conn = deliver(%Electric.Client.Fetch.Response{status: 200, body: body})
      assert conn.resp_body == IO.iodata_to_binary(body)
    end
  end

  test "decoded and raw transformed rows are encoded once and retain control messages" do
    rows = [
      %{"key" => "row-1", "headers" => %{}, "value" => %{"label" => "Visible", "hidden" => true}},
      %{"headers" => %{"control" => "up-to-date"}}
    ]

    shape =
      Phoenix.Sync.PredefinedShape.new!(
        table: "todos",
        transform: fn message ->
          Map.update!(message, "value", &Map.delete(&1, "hidden"))
        end
      )

    for body <- [rows, Jason.encode!(rows)] do
      {:ok, client} =
        Electric.Client.new(
          base_url: "elixir://#{inspect(ResponseFetch)}",
          fetch:
            {ResponseFetch, response: %Electric.Client.Fetch.Response{status: 200, body: body}}
        )

      {:ok, adapter} =
        Phoenix.Sync.Adapter.PlugApi.predefined_shape(%ClientAdapter{client: client}, shape)

      conn = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn(:get, "/shape"), %{"offset" => "-1"})

      assert [
               %{"value" => %{"label" => "Visible"}},
               %{"headers" => %{"control" => "up-to-date"}}
             ] = Jason.decode!(conn.resp_body)

      refute conn.resp_body =~ "hidden"
    end
  end

  test "serialized bodies do not retain an upstream content length" do
    response = %Electric.Client.Fetch.Response{
      status: 200,
      body: [%{"headers" => %{"control" => "up-to-date"}}],
      headers: %{"content-length" => ["999999"], "electric-handle" => ["current-handle"]}
    }

    conn = deliver(response)
    assert Plug.Conn.get_resp_header(conn, "content-length") == []
    assert Plug.Conn.get_resp_header(conn, "electric-handle") == ["current-handle"]
  end

  test "forwards request headers to sync server" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {MockFetch, parent: self()}
      )

    adapter = %ClientAdapter{client: client}

    conn =
      conn(:get, "/v1/shapes", %{})
      |> Plug.Conn.put_req_header("my-header-1", "my-header-1-value-1")
      |> Plug.Conn.prepend_req_headers([{"my-header-1", "my-header-1-value-2"}])
      |> Plug.Conn.put_req_header("my-header-2", "my-header-2-value")

    assert %{status: 200} = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn, %{offset: -1})
    assert_receive {:fetch_request, request}

    assert request.headers == [
             {"my-header-1", "my-header-1-value-1"},
             {"my-header-1", "my-header-1-value-2"},
             {"my-header-2", "my-header-2-value"}
           ]
  end

  test "returns a safe gateway error when Electric transport is unavailable" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {TransportErrorFetch, []}
      )

    adapter = %ClientAdapter{client: client}
    conn = conn(:get, "/v1/shapes", %{})

    response = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn, %{offset: -1})

    assert response.status == 502

    assert Plug.Conn.get_resp_header(response, "content-type") == [
             "application/json; charset=utf-8"
           ]

    assert Jason.decode!(response.resp_body) == %{"error" => "electric_upstream_unavailable"}
    refute response.resp_body =~ "pool_not_available"
  end

  defp deliver(response) do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(ResponseFetch)}",
        fetch: {ResponseFetch, response: response}
      )

    adapter = %ClientAdapter{client: client}
    Phoenix.Sync.Adapter.PlugApi.call(adapter, conn(:get, "/shape"), %{"offset" => "-1"})
  end
end
