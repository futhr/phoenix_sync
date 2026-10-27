defmodule Phoenix.Sync.ElectricHTTPConfigTest do
  use ExUnit.Case, async: false

  test "HTTP service headers survive direct client and raw proxy configuration" do
    config = [
      env: :test,
      mode: :http,
      url: "https://electric.example.test",
      headers: [{"authorization", "Bearer synthetic-service-token"}]
    ]

    {:ok, direct} = Phoenix.Sync.Electric.client(:test, config)

    %Phoenix.Sync.Electric.ClientAdapter{client: proxy} =
      Phoenix.Sync.Application.plug_opts(config)

    for client <- [direct, proxy] do
      {Electric.Client.Fetch.HTTP, opts} = client.fetch

      request =
        Electric.Client.Fetch.HTTP.build_request(
          %Electric.Client.Fetch.Request{
            endpoint: client.endpoint,
            params: client.params,
            authenticated: true
          },
          opts
        )

      assert request.headers["authorization"] == ["Bearer synthetic-service-token"]
      refute URI.to_string(request.url) =~ "synthetic-service-token"
      refute request.url.query =~ "secret="
    end

    {_, proxy_opts} = proxy.fetch
    assert proxy_opts[:request][:raw]
  end
end
