defmodule Phoenix.Sync.Electric.ClientAdapter do
  @moduledoc false

  defstruct [:client, :shape_definition]

  @type t :: %__MODULE__{
          client: Electric.Client.t(),
          shape_definition: Phoenix.Sync.PredefinedShape.t() | nil
        }

  defimpl Phoenix.Sync.Adapter.PlugApi do
    alias Electric.Client

    alias Phoenix.Sync.PredefinedShape

    @json Phoenix.Sync.json_library()

    def predefined_shape(sync_client, %PredefinedShape{} = predefined_shape) do
      shape_client = PredefinedShape.client(sync_client.client, predefined_shape)

      {:ok,
       %Phoenix.Sync.Electric.ClientAdapter{
         client: shape_client,
         shape_definition: predefined_shape
       }}
    end

    def call(sync_client, conn, params) do
      {request, shape} = request(sync_client, conn, params)

      fetch_upstream(sync_client, conn, request, shape)
    end

    def response(sync_client, %{method: "GET"} = conn, params) do
      {request, shape} = request(sync_client, conn, params)

      make_request(sync_client, conn, request, shape)
    end

    def send_response(_sync_client, conn, response) do
      conn
      |> put_resp_headers(response.headers)
      |> Plug.Conn.send_resp(response.status, response.body)
    end

    # this is the server-defined shape route, so we want to only pass on the
    # per-request/stream position params leaving the shape-definition params
    # from the configured client.
    defp request(%{shape_definition: %PredefinedShape{} = shape} = sync_client, _conn, params) do
      {
        Client.request(
          sync_client.client,
          method: :get,
          offset: params["offset"],
          shape_handle: params["handle"],
          live: live?(params["live"]),
          next_cursor: params["cursor"]
        ),
        shape
      }
    end

    # this version is the pure client-defined shape version
    defp request(sync_client, %{method: method} = _conn, params) do
      {
        Client.request(
          sync_client.client,
          method: normalise_method(method),
          params: params
        ),
        nil
      }
    end

    defp normalise_method(method), do: method |> String.downcase() |> String.to_atom()
    defp live?(live), do: live == "true"

    defp fetch_upstream(sync_client, conn, request, shape) do
      response = make_request(sync_client, conn, request, shape)

      send_response(sync_client, conn, response)
    end

    defp make_request(sync_client, conn, request, shape) do
      request = put_req_headers(request, conn.req_headers)

      response =
        case Client.Fetch.request(sync_client.client, request) do
          %Client.Fetch.Response{} = response -> response
          {:error, %Client.Fetch.Response{} = response} -> response
          {:error, _reason} -> upstream_unavailable_response()
        end

      body =
        if response.status == 200 do
          Phoenix.Sync.Electric.map_response_body(
            response.body,
            PredefinedShape.transform_fun(shape)
          )
        else
          response.body
        end

      %{response | body: encode_body(body)}
    end

    defp encode_body(body) when is_map(body), do: @json.encode_to_iodata!(body)
    defp encode_body([message | _] = body) when is_map(message), do: @json.encode_to_iodata!(body)
    defp encode_body([]), do: @json.encode_to_iodata!([])
    defp encode_body(body), do: body

    defp upstream_unavailable_response do
      %Client.Fetch.Response{
        status: 502,
        headers: %{"content-type" => ["application/json; charset=utf-8"]},
        body: Jason.encode!(%{error: "electric_upstream_unavailable"})
      }
    end

    defp put_req_headers(request, headers) do
      merged_headers =
        Enum.reduce(headers, request.headers, fn {header, value}, acc ->
          Map.update(acc, header, [value], fn existing -> [value | List.wrap(existing)] end)
        end)
        |> expand_headers()

      %{request | headers: merged_headers}
    end

    defp put_resp_headers(conn, headers) do
      resp_headers =
        headers
        |> Map.delete("transfer-encoding")
        |> Map.delete("content-length")
        |> expand_headers()

      Plug.Conn.merge_resp_headers(conn, resp_headers)
    end

    # turn headers into a list which is more compatible than a map
    # representation as it preserves multiple values for a header.
    defp expand_headers(headers) when is_map(headers) do
      Enum.flat_map(headers, fn {k, v} -> Enum.map(List.wrap(v), &{k, &1}) end)
    end
  end
end
