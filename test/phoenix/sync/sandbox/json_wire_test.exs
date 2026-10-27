defmodule Phoenix.Sync.Sandbox.JSONWireTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Support.RepoSetup, repo: Support.SandboxRepo

  import Ecto.Query

  alias Electric.Client.Message.{ChangeMessage, ControlMessage}
  alias Support.SandboxRepo, as: Repo

  defmodule Record do
    @moduledoc false

    use Ecto.Schema

    schema "json_wire_records" do
      field :label, :string
      field :details, :map, read_after_writes: true
      field :resources, {:array, :map}, read_after_writes: true
      field :aliased, :map, source: :stored_details, read_after_writes: true
    end
  end

  @moduletag :sandbox
  @moduletag table:
               {"json_wire_records",
                [
                  "id bigint primary key",
                  "label text",
                  "details jsonb",
                  "resources jsonb[]",
                  "stored_details jsonb"
                ]}

  @initial ~s({"amount":9007199254740993.123456789,"zero":0,"empty":"","false":false,"nil":null})
  @updated ~s({"amount":9007199254740993.987654321,"nested":{"fraction":0.1234567890123456789}})

  setup ctx do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Phoenix.Sync.Sandbox.start!(Repo, tags: ctx)
    :ok
  end

  setup [:with_repo_table]

  setup do
    Repo.query!(
      "INSERT INTO json_wire_records(id,label,details,resources,stored_details) VALUES (1,'Initial',$1::text::jsonb,ARRAY[$1::text::jsonb],$1::text::jsonb)",
      [@initial]
    )

    {:ok, client} = Phoenix.Sync.Sandbox.client()
    shape = Electric.Client.ShapeDefinition.new!("json_wire_records", replica: :full)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         for message <- Electric.Client.stream(client, shape, replica: :full),
             do: send(parent, {:wire, message})
       end}
    )

    assert_receive {:wire, %ChangeMessage{value: snapshot}}, 5_000
    assert snapshot["details"] =~ "9007199254740993.123456789"
    assert snapshot["stored_details"] =~ "9007199254740993.123456789"
    assert_receive {:wire, %ControlMessage{control: :up_to_date}}, 5_000
    :ok
  end

  test "update_all emits exact JSONB and map-array text while preserving ordinary returning values" do
    query =
      from row in Record,
        where: row.id == 1,
        update: [
          set: [
            label: "Updated",
            details: fragment("?::text::jsonb", ^@updated),
            resources: fragment("ARRAY[?::text::jsonb]", ^@updated)
          ]
        ],
        select: row

    assert {1, [returned]} = Repo.update_all(query, [])
    assert is_map(returned.details)
    assert is_float(returned.details["amount"])
    assert [%{"amount" => _}] = returned.resources
    assert_receive {:wire, %ChangeMessage{value: changed, headers: %{operation: :update}}}, 5_000
    assert_exact(changed)
  end

  test "schema updates preserve unchanged numeric evidence and exact replaced maps" do
    record = Repo.get!(Record, 1)
    returned = Repo.update!(Ecto.Changeset.change(record, label: "First update"))
    assert is_float(returned.details["amount"])

    assert_receive {:wire, %ChangeMessage{value: unchanged, headers: %{operation: :update}}},
                   5_000

    assert unchanged["details"] =~ "9007199254740993.123456789"
    assert unchanged["stored_details"] =~ "9007199254740993.123456789"
    refute Map.has_key?(unchanged, "aliased")
    assert is_float(returned.aliased["amount"])

    values = %{
      "amount" => Jason.Fragment.new("9007199254740993.987654321"),
      "nested" => %{"fraction" => Jason.Fragment.new("0.1234567890123456789")}
    }

    returned = Repo.update!(Ecto.Changeset.change(returned, details: values, resources: [values]))
    assert is_float(returned.details["amount"])
    assert [%{"amount" => _}] = returned.resources
    assert_receive {:wire, %ChangeMessage{value: changed, headers: %{operation: :update}}}, 5_000
    assert_exact(changed)
  end

  test "SQL NULL and empty JSON map arrays retain distinct wire values" do
    query = from row in Record, where: row.id == 1, update: [set: [details: nil, resources: nil]]
    assert {1, nil} = Repo.update_all(query, [])
    assert_receive {:wire, %ChangeMessage{value: changed, headers: %{operation: :update}}}, 5_000
    assert changed["details"] == nil
    assert changed["resources"] == nil

    assert {1, nil} =
             Repo.update_all(from(row in Record, where: row.id == 1),
               set: [details: %{}, resources: []]
             )

    assert_receive {:wire, %ChangeMessage{value: empty, headers: %{operation: :update}}}, 5_000
    assert empty["details"] == "{}"
    assert empty["resources"] == "{}"
  end

  test "JSON null is distinct from a SQL NULL in JSONB capture" do
    query =
      from row in Record,
        where: row.id == 1,
        update: [
          set: [
            details: fragment("'null'::jsonb"),
            resources: fragment("ARRAY['null'::jsonb,NULL]")
          ]
        ]

    assert {1, nil} = Repo.update_all(query, [])
    assert_receive {:wire, %ChangeMessage{value: changed, headers: %{operation: :update}}}, 5_000
    assert changed["details"] == "null"

    %{rows: [[resources]]} =
      Repo.query!("SELECT resources::text FROM json_wire_records WHERE id = 1")

    assert changed["resources"] == resources
  end

  defp assert_exact(changed) do
    %{rows: [[details, resources]]} =
      Repo.query!("SELECT details::text, resources::text FROM json_wire_records WHERE id=1")

    assert changed["details"] == details
    assert changed["resources"] == resources
    assert changed["details"] =~ "9007199254740993.987654321"
    assert changed["resources"] =~ "0.1234567890123456789"
  end
end
