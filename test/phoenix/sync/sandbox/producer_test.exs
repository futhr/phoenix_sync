defmodule Phoenix.Sync.Sandbox.ProducerTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Support.RepoSetup, repo: Support.SandboxRepo

  doctest Phoenix.Sync.Sandbox.Producer, import: true

  alias Electric.Client.Message.{ChangeMessage, ControlMessage}
  alias Phoenix.Sync.Sandbox.Producer
  alias Support.SandboxRepo, as: Repo

  defmodule Record do
    @moduledoc false

    use Ecto.Schema

    schema "producer_empty_records" do
      field :label, :string
    end
  end

  @moduletag :sandbox
  @moduletag table: {"producer_empty_records", ["id bigint primary key", "label text"]}

  setup ctx do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Phoenix.Sync.Sandbox.start!(Repo, tags: ctx)
    :ok
  end

  setup [:with_repo_table]

  test "zero-row writes preserve the producer and subsequent native delivery" do
    import Ecto.Query

    record = Repo.insert!(%Record{id: 1, label: "Initial"})
    {:ok, client} = Phoenix.Sync.Sandbox.client()
    shape = Electric.Client.ShapeDefinition.new!("producer_empty_records", replica: :full)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         for message <- Electric.Client.stream(client, shape, replica: :full),
             do: send(parent, {:wire, message})
       end}
    )

    assert_receive {:wire, %ChangeMessage{value: %{"label" => "Initial"}}}, 5_000
    assert_receive {:wire, %ControlMessage{control: :up_to_date}}, 5_000

    name = Producer.name(Phoenix.Sync.Sandbox.stack_id!())
    producer = GenServer.whereis(name)
    before = :sys.get_state(producer)

    assert {0, nil} =
             Repo.update_all(from(row in Record, where: row.id == -1), set: [label: "Absent"])

    assert {0, nil} = Repo.delete_all(from(row in Record, where: row.id == -1))

    assert {0, nil} =
             Repo.insert_all(Record, [%{id: 1, label: "Ignored duplicate"}],
               on_conflict: :nothing
             )

    after_empty = :sys.get_state(producer)
    assert GenServer.whereis(name) == producer
    assert after_empty.txid == before.txid

    Repo.update!(Ecto.Changeset.change(record, label: "After empty writes"))

    assert_receive {:wire,
                    %ChangeMessage{
                      value: %{"label" => "After empty writes"},
                      headers: %{operation: :update}
                    }},
                   5_000
  end
end
