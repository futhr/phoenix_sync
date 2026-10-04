defmodule Phoenix.Sync.Sandbox.UUIDWireTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Support.RepoSetup, repo: Support.SandboxRepo

  alias Electric.Client.Message.{ChangeMessage, ControlMessage}
  alias Support.SandboxRepo, as: Repo

  defmodule Record do
    @moduledoc false

    use Ecto.Schema

    @primary_key {:id, Support.ULID, prefix: "record"}
    schema "uuid_wire_records" do
      field :owner_id, Support.ULID, prefix: "owner"
      field :optional_id, Support.ULID, prefix: "optional"
      field :related_ids, {:array, Support.ULID}, prefix: "related"
      field :label, :string
      field :quantity, :integer
    end
  end

  @moduletag :sandbox
  @moduletag table:
               {"uuid_wire_records",
                [
                  "id uuid primary key",
                  "owner_id uuid not null",
                  "optional_id uuid",
                  "related_ids uuid[]",
                  "label text",
                  "quantity integer"
                ]}

  setup ctx do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Phoenix.Sync.Sandbox.start!(Repo, tags: ctx)
    :ok
  end

  setup [:with_repo_table]

  test "filtered snapshots and changes share PostgreSQL UUID text" do
    id = Ecto.UUID.generate()
    owner_id = Ecto.UUID.generate()
    other_owner_id = Ecto.UUID.generate()
    related_id = Ecto.UUID.generate()

    record =
      Repo.insert!(%Record{
        id: prefixed(id, "record"),
        owner_id: prefixed(owner_id, "owner"),
        related_ids: [prefixed(related_id, "related"), nil],
        label: "0123456789abcdef",
        quantity: 7
      })

    {:ok, client} = Phoenix.Sync.Sandbox.client()

    shape =
      Electric.Client.ShapeDefinition.new!("uuid_wire_records",
        where: "owner_id = '#{owner_id}'",
        replica: :full
      )

    parent = self()

    start_supervised!(
      {Task,
       fn ->
         for message <- Electric.Client.stream(client, shape, replica: :full),
             do: send(parent, {:wire, message})
       end}
    )

    assert_receive {:wire, %ChangeMessage{value: snapshot, headers: %{operation: :insert}}}, 5_000
    assert snapshot["id"] == id
    assert snapshot["owner_id"] == owner_id
    assert snapshot["optional_id"] == nil
    assert snapshot["related_ids"] == "{#{related_id},NULL}"
    assert snapshot["label"] == "0123456789abcdef"
    assert snapshot["quantity"] == 7
    assert_receive {:wire, %ControlMessage{control: :up_to_date}}, 5_000

    record =
      record
      |> Ecto.Changeset.change(label: "Updated", optional_id: prefixed(related_id, "optional"))
      |> Repo.update!()

    assert_receive {:wire, %ChangeMessage{value: updated, headers: %{operation: :update}}}, 5_000

    assert Map.drop(updated, ["related_ids"]) ==
             %{
               Map.drop(snapshot, ["related_ids"])
               | "label" => "Updated",
                 "optional_id" => related_id
             }

    assert updated["related_ids"] in ["{#{related_id},NULL}", ~s({"#{related_id}",NULL})]

    inserted_id = Ecto.UUID.generate()

    inserted =
      Repo.insert!(%Record{
        id: prefixed(inserted_id, "record"),
        owner_id: record.owner_id,
        related_ids: [nil, prefixed(id, "related")],
        label: "Inserted",
        quantity: 8
      })

    assert_receive {:wire, %ChangeMessage{value: added, headers: %{operation: :insert}}}, 5_000
    assert added["id"] == inserted_id
    assert added["owner_id"] == owner_id
    assert added["related_ids"] in ["{NULL,#{id}}", ~s({NULL,"#{id}"})]
    assert added["optional_id"] == nil

    record =
      record
      |> Ecto.Changeset.change(owner_id: prefixed(other_owner_id, "owner"))
      |> Repo.update!()

    assert_receive {:wire, %ChangeMessage{value: removed, headers: %{operation: :delete}}}, 5_000
    assert removed["id"] == id

    record |> Ecto.Changeset.change(owner_id: prefixed(owner_id, "owner")) |> Repo.update!()
    assert_receive {:wire, %ChangeMessage{value: returned, headers: %{operation: :insert}}}, 5_000
    assert returned == updated

    Repo.delete!(inserted)
    assert_receive {:wire, %ChangeMessage{value: deleted, headers: %{operation: :delete}}}, 5_000
    assert deleted["id"] == inserted_id
  end

  defp prefixed(uuid, prefix) do
    prefix <> "_" <> Base.encode32(Ecto.UUID.dump!(uuid), case: :lower, padding: false)
  end
end
