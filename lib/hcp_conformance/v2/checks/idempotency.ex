defmodule HcpConformance.V2.Checks.Idempotency do
  @moduledoc """
  Idempotency of create and revise (§9.6): a retried request with the same key
  and body returns the original response and does nothing twice; the same key
  with another body is a conflict.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, V2.Fixtures}

  def group, do: "idempotency"

  def checks do
    person = [requires: [:rest, :person]]

    [
      Check.new(
        "idempotency.create_replay",
        "9.6",
        :must,
        "A replayed create returns the original entry id and version",
        &create_replay/1,
        person
      ),
      Check.new(
        "idempotency.create_single_event",
        "9.6",
        :must,
        "A replayed create appends no second context.created",
        &create_single_event/1,
        person
      ),
      Check.new(
        "idempotency.create_conflict",
        "9.6",
        :must,
        "A create reusing a key with a different body is refused with 409 idempotency-conflict",
        &create_conflict/1,
        person
      ),
      Check.new(
        "idempotency.revision_replay",
        "9.6",
        :must,
        "A replayed revision returns the original version instead of a version conflict",
        &revision_replay/1,
        person
      ),
      Check.new(
        "idempotency.revision_conflict",
        "9.6",
        :must,
        "A revision reusing a key with a different body is refused with 409 idempotency-conflict",
        &revision_conflict/1,
        person
      ),
      Check.new(
        "idempotency.delete_key",
        "9.6",
        :should,
        "DELETE accepts Idempotency-Key, and a replay appends no second audit event",
        &delete_key/1,
        person
      )
    ]
  end

  defp key(ctx), do: [headers: [{"idempotency-key", "hcpc-" <> Context.unique_word(ctx)}]]
  defp person(ctx), do: Context.person!(ctx)

  defp create_twice!(ctx) do
    key = key(ctx)
    body = Fixtures.entry_body(ctx)

    first =
      ctx
      |> Fixtures.post(person(ctx), body, key)
      |> Assert.status!(201, "POST /v2/entries with Idempotency-Key")

    id = Assert.json_object!(first, "POST /v2/entries")["id"]
    if is_binary(id), do: Context.track_entry(ctx, id)
    second = Fixtures.post(ctx, person(ctx), body, key)
    {first, second}
  end

  defp create_replay(ctx) do
    {first, second} = create_twice!(ctx)
    Assert.status!(second, 201, "the replayed POST /v2/entries")
    replay = Assert.json_object!(second, "the replayed POST /v2/entries")

    Assert.check!(
      replay["id"] == first.json["id"],
      "the replay created another entry: #{inspect(replay["id"])}"
    )

    Assert.check!(
      get_in(replay, ["record", "version"]) == 1,
      "the replay does not carry the original version"
    )
  end

  # Counted over the log, not by entry id: a provider that repeats the operation
  # creates a second entry, whose event names another id.
  defp create_single_event(ctx) do
    created = fn ->
      ctx |> AuditLog.fetch!() |> Enum.count(&AuditLog.event?(&1, "context.created"))
    end

    before = created.()
    {first, _second} = create_twice!(ctx)

    AuditLog.await!(
      ctx,
      "context.created",
      &AuditLog.event?(&1, "context.created", entryId: first.json["id"])
    )

    extra = created.() - before - 1
    Assert.check!(extra == 0, "the replay appended #{extra} extra context.created")
  end

  defp create_conflict(ctx) do
    key = key(ctx)

    first =
      ctx
      |> Fixtures.post(person(ctx), Fixtures.entry_body(ctx), key)
      |> Assert.status!(201, "POST /v2/entries")

    if is_map(first.json) and is_binary(first.json["id"]),
      do: Context.track_entry(ctx, first.json["id"])

    response = Fixtures.post(ctx, person(ctx), Fixtures.entry_body(ctx), key)
    Assert.problem!(response, 409, "idempotency-conflict", "a key reused with a different body")
  end

  defp revision_replay(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    key = key(ctx)

    body = %{
      "expectedVersion" => 1,
      "content" => %{
        "profile" => Fixtures.general_context(),
        "value" => "Replayed revision " <> ctx.nonce
      }
    }

    Assert.status!(
      Fixtures.revise(ctx, person(ctx), created["id"], body, key),
      201,
      "the revision"
    )

    replay = Fixtures.revise(ctx, person(ctx), created["id"], body, key)
    Assert.status!(replay, 201, "the replayed revision")

    Assert.check!(
      get_in(replay.json, ["record", "version"]) == 2,
      "the replay does not carry the original version 2"
    )

    current = Fixtures.get!(ctx, person(ctx), created["id"])

    Assert.check!(
      get_in(current, ["record", "version"]) == 2,
      "the replay created another version"
    )
  end

  defp revision_conflict(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    key = key(ctx)

    Assert.status!(
      Fixtures.revise(ctx, person(ctx), created["id"], %{"expectedVersion" => 1}, key),
      201,
      "the revision"
    )

    response = Fixtures.revise(ctx, person(ctx), created["id"], %{"expectedVersion" => 1}, key)

    Assert.problem!(
      response,
      409,
      "idempotency-conflict",
      "a revision key reused with a different body"
    )
  end

  defp delete_key(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    key = key(ctx)

    Assert.status!(
      Fixtures.delete(ctx, person(ctx), created["id"], key),
      200,
      "DELETE with Idempotency-Key"
    )

    Assert.status!(
      Fixtures.delete(ctx, person(ctx), created["id"], key),
      200,
      "the replayed DELETE"
    )

    events =
      AuditLog.await!(
        ctx,
        "context.withdrawn",
        &AuditLog.event?(&1, "context.withdrawn", entryId: created["id"])
      )

    Assert.check!(
      length(events) == 1,
      "the replayed DELETE appended #{length(events) - 1} extra context.withdrawn"
    )
  end
end
