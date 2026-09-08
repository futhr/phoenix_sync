defmodule Phoenix.Sync.Sandbox.InspectorTest do
  use ExUnit.Case, async: true

  alias Phoenix.Sync.Sandbox.Inspector
  alias Support.SandboxRepo, as: Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    stack_id = "inspector-#{System.unique_integer([:positive])}"
    start_supervised!({Inspector, stack_id: stack_id, repo: Repo, owner: self()})
    table = "inspector_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE TABLE #{table} (id bigint PRIMARY KEY)")
    %{stack_id: stack_id, table: table, relation: {"public", table}}
  end

  test "clean reloads columns after transactional DDL", ctx do
    assert {:ok, {oid, _relation}} = Inspector.load_relation_oid(ctx.relation, ctx.stack_id)
    assert {:ok, [%{name: "id"}]} = Inspector.load_column_info(oid, ctx.stack_id)

    Repo.query!("ALTER TABLE #{ctx.table} ADD COLUMN title text")
    assert {:ok, [%{name: "id"}]} = Inspector.load_column_info(oid, ctx.stack_id)
    assert :ok = Inspector.clean(oid, ctx.stack_id)
    assert {:ok, columns} = Inspector.load_column_info(oid, ctx.stack_id)
    assert Enum.map(columns, & &1.name) == ["id", "title"]
  end

  test "reset reloads relation identities after a table is recreated", ctx do
    assert {:ok, {original_oid, _relation}} =
             Inspector.load_relation_oid(ctx.relation, ctx.stack_id)

    assert {:ok, _} = Inspector.load_relation_info(original_oid, ctx.stack_id)
    assert {:ok, _} = Inspector.load_supported_features(ctx.stack_id)
    Repo.query!("DROP TABLE #{ctx.table}")
    Repo.query!("CREATE TABLE #{ctx.table} (replacement uuid DEFAULT uuidv7())")

    assert :ok = Inspector.reset(ctx.stack_id)

    assert {:ok, {new_oid, _relation}} =
             Inspector.load_relation_oid(ctx.relation, ctx.stack_id)

    assert new_oid != original_oid
    assert :table_not_found = Inspector.load_relation_info(original_oid, ctx.stack_id)
    assert {:ok, [%{name: "replacement"}]} = Inspector.load_column_info(new_oid, ctx.stack_id)

    assert {:ok, %{supports_generated_column_replication: true}} =
             Inspector.load_supported_features(ctx.stack_id)
  end

  test "reset is idempotent after the sandbox ends", ctx do
    stop_supervised!(Inspector)
    assert :ok = Inspector.reset(ctx.stack_id)
  end
end
