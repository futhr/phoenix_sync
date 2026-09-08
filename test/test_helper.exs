{:ok, _} = Support.SandboxRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Support.SandboxRepo, :manual)
{:ok, _} = Phoenix.Sync.LiveViewTest.Endpoint.start_link()

ExUnit.start(capture_log: true)
