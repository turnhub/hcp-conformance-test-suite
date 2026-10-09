defmodule HcpConformance.Checks.Idempotency do
  @moduledoc """
  Idempotency-Key handling (§3.4.3): a replay with the same key and body returns
  the original response without repeating the operation or its audit event; the
  same key with a different body is refused with 409.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, Envelope, Fixtures}

  def group, do: "idempotency"

  def checks do
    person = [requires: [:rest, :person]]

    [
      Check.new(
        "idempotency.post_replay",
        "3.4.3",
        :must,
        "A replayed POST returns the original entry id and version",
        &post_replay/1,
        person
      ),
      Check.new(
        "idempotency.post_single_event",
        "3.4.3",
        :must,
        "A replayed POST appends no second preference.created",
        &post_single_event/1,
        person
      ),
      Check.new(
        "idempotency.post_conflict",
        "3.4.3",
        :must,
        "A POST reusing a key with a different body is refused with 409 idempotency-conflict",
        &post_conflict/1,
        person
      ),
      Check.new(
        "idempotency.put_replay",
        "3.4.3",
        :must,
        "A replayed PUT returns the original version and creates no extra version",
        &put_replay/1,
        person
      ),
      Check.new(
        "idempotency.put_conflict",
        "3.4.3",
        :must,
        "A PUT reusing a key with a different body is refused with 409 idempotency-conflict",
        &put_conflict/1,
        person
      ),
      Check.new(
        "idempotency.delete_key",
        "3.4.3",
        :should,
        "DELETE accepts Idempotency-Key, and a replay appends no second audit event",
        &delete_key/1,
        person
      )
    ]
  end

  defp key, do: "hcp-conformance-" <> Context.random_word(20)

  defp post(ctx, key, body) do
    Context.request(ctx, :post, Context.url(ctx, :preferences),
      token: Context.person!(ctx),
      json: body,
      headers: [{"idempotency-key", key}]
    )
  end

  defp replayed_pair(ctx) do
    key = key()
    body = Fixtures.entry_body(ctx)

    first =
      post(ctx, key, body)
      |> Assert.status!(201, "first POST with Idempotency-Key")
      |> Assert.json_object!("first POST")

    Context.track_entry(ctx, first["id"])
    second = post(ctx, key, body)
    Assert.status!(second, 201, "replayed POST (the original response, 201, is expected)")
    {first, Assert.json_object!(second, "replayed POST")}
  end

  defp post_replay(ctx) do
    {first, second} = replayed_pair(ctx)
    version = &Envelope.get(&1, ctx.envelope_form, ["record", "version"])

    Assert.check!(
      second["id"] == first["id"],
      "the replay created a different entry (#{first["id"]} then #{second["id"]})"
    )

    Assert.check!(
      version.(second) == version.(first),
      "the replay returned a different record.version"
    )
  end

  # A replay that ignored the key creates a second entry, so the events of both
  # responses are counted together: exactly one creation may have happened.
  defp post_single_event(ctx) do
    {first, second} = replayed_pair(ctx)
    ids = Enum.uniq([first["id"], second["id"]])

    events =
      AuditLog.await!(
        ctx,
        "preference.created",
        &(AuditLog.event?(&1, "preference.created") and &1["entryId"] in ids)
      )

    Assert.check!(
      length(events) == 1,
      "expected one preference.created for the request and its replay, found #{length(events)}"
    )
  end

  defp post_conflict(ctx) do
    key = key()

    first =
      post(ctx, key, Fixtures.entry_body(ctx))
      |> Assert.status!(201, "first POST")
      |> Assert.json_object!("first POST")

    Context.track_entry(ctx, first["id"])
    response = post(ctx, key, Fixtures.entry_body(ctx))

    Assert.problem!(
      response,
      409,
      "idempotency-conflict",
      "POST reusing a key with a different body"
    )
  end

  defp put(ctx, id, key, text) do
    Context.request(ctx, :put, Context.entry_url(ctx, id),
      token: Context.person!(ctx),
      json: %{"updatedPreference" => text, "reason" => "HCP conformance check"},
      headers: [{"idempotency-key", key}]
    )
  end

  defp put_replay(ctx) do
    entry = Fixtures.create!(ctx, Context.person!(ctx))
    key = key()
    text = "Replayed update " <> Context.unique_word(ctx)
    version = &Envelope.get(&1, ctx.envelope_form, ["record", "version"])

    first =
      put(ctx, entry["id"], key, text)
      |> Assert.status!(200, "first PUT")
      |> Assert.json_object!("first PUT")

    second =
      put(ctx, entry["id"], key, text)
      |> Assert.status!(200, "replayed PUT")
      |> Assert.json_object!("replayed PUT")

    Assert.check!(
      version.(first) == 2 and version.(second) == 2,
      "the replay must return version 2 again, got #{inspect(version.(second))}"
    )

    current =
      Fixtures.get(ctx, Context.person!(ctx), entry["id"])
      |> Assert.status!(200, "GET after replay")
      |> Assert.json_object!("GET")

    Assert.check!(version.(current["entry"] || %{}) == 2, "the replay created another version")
  end

  defp put_conflict(ctx) do
    entry = Fixtures.create!(ctx, Context.person!(ctx))
    key = key()

    put(ctx, entry["id"], key, "First " <> Context.unique_word(ctx))
    |> Assert.status!(200, "first PUT")

    response = put(ctx, entry["id"], key, "Different " <> Context.unique_word(ctx))

    Assert.problem!(
      response,
      409,
      "idempotency-conflict",
      "PUT reusing a key with a different body"
    )
  end

  defp delete_key(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    key = key()

    for attempt <- ["first", "replayed"] do
      Context.request(ctx, :delete, Context.entry_url(ctx, entry["id"]),
        token: token,
        headers: [{"idempotency-key", key}]
      )
      |> Assert.status!(200, "#{attempt} DELETE with Idempotency-Key")
    end

    events =
      AuditLog.await!(
        ctx,
        "preference.deleted",
        &AuditLog.event?(&1, "preference.deleted", entryId: entry["id"])
      )

    Assert.check!(length(events) == 1, "expected one preference.deleted, found #{length(events)}")
  end
end
