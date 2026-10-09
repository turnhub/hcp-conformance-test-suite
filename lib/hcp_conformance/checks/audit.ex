defmodule HcpConformance.Checks.Audit do
  @moduledoc """
  The person's audit log (§4.3) and its pagination (§3.4.2). The per-operation
  events are checked where each operation is exercised; this group checks the log
  as a whole.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, Envelope, Fixtures}

  @event_types ~w(preference.created preference.read preference.updated preference.deleted preference.hardDeleted
                  preference.exported grant.issued grant.revoked grant.expired conflict.detected conflict.resolved
                  revocation.notified)
  @actor_types ["user", "agent", "system"]

  def group, do: "audit"

  def checks do
    person = [requires: [:rest, :person]]

    [
      Check.new(
        "audit.agents_refused",
        "4.3.3",
        :must,
        "Third-party agents cannot read the audit log",
        &agents_refused/1,
        requires: [:rest, :agent]
      ),
      Check.new(
        "audit.event_structure",
        "4.3.2",
        :must,
        "Every event follows the log entry structure, with registered event and actor types",
        &event_structure/1,
        person
      ),
      Check.new(
        "audit.pagination",
        "3.4.2",
        :must,
        "limit bounds a page, and nextCursor continues without gaps or repeats",
        &pagination/1,
        person
      ),
      Check.new(
        "audit.cursor_opaque",
        "3.4.2",
        :must,
        "Cursors are opaque: not a bare sequence number or offset",
        &cursor_opaque/1,
        person
      ),
      Check.new(
        "audit.cursor_exhausted",
        "3.4.2",
        :must,
        "The last page carries nextCursor: null",
        &cursor_exhausted/1,
        person
      ),
      Check.new(
        "audit.append_only",
        "4.3",
        :must,
        "Earlier events are never changed or removed by later operations",
        &append_only/1,
        person
      )
    ]
  end

  defp page!(ctx, params) do
    response =
      Context.request(ctx, :get, Context.url(ctx, :audit), token: Context.person!(ctx), params: params)

    Assert.status!(response, 200, "GET /v1/audit")
    body = Assert.json_object!(response, "GET /v1/audit")
    Assert.check!(is_list(body["events"]), "the body must carry an events array")
    body
  end

  defp ensure_events!(ctx, count) do
    for _ <- 1..count, do: Fixtures.create!(ctx, Context.person!(ctx))
  end

  defp agents_refused(ctx) do
    response = Context.request(ctx, :get, Context.url(ctx, :audit), token: Context.agent!(ctx).token)
    Assert.refused!(response, "an agent reading the audit log")
  end

  defp event_structure(ctx) do
    ensure_events!(ctx, 1)
    events = AuditLog.fetch!(ctx)
    Assert.check!(events != [], "the audit log is empty after an entry was created")

    violations =
      events
      |> Enum.flat_map(fn event ->
        [
          {is_binary(event["eventId"]), "eventId must be a string"},
          {event["eventType"] in @event_types,
           "eventType #{inspect(event["eventType"])} is not a registered event type"},
          {Envelope.iso8601?(event["timestamp"]), "timestamp must be ISO-8601"},
          {is_binary(event["actorId"]) and event["actorId"] != "", "actorId must be a non-empty string"},
          {event["actorType"] in @actor_types,
           "actorType must be user, agent or system, got #{inspect(event["actorType"])}"}
        ]
        |> Enum.reject(&elem(&1, 0))
        |> Enum.map(&"event #{inspect(event["eventId"])}: #{elem(&1, 1)}")
      end)
      |> Enum.uniq()

    Assert.check!(
      violations == [],
      Enum.take(violations, 5) |> Enum.join("; ") |> then(&(&1 <> more(violations)))
    )
  end

  defp more(list) when length(list) > 5, do: " (and #{length(list) - 5} more)"
  defp more(_list), do: ""

  defp pagination(ctx) do
    ensure_events!(ctx, 3)
    first = page!(ctx, limit: 1)
    Assert.check!(length(first["events"]) == 1, "limit=1 returned #{length(first["events"])} events")
    cursor = first["nextCursor"]

    Assert.check!(
      is_binary(cursor) and cursor != "",
      "more events exist, but nextCursor is #{inspect(cursor)}"
    )

    second = page!(ctx, limit: 1, cursor: cursor)

    Assert.check!(
      length(second["events"]) == 1,
      "the second page returned #{length(second["events"])} events"
    )

    [a] = first["events"]
    [b] = second["events"]
    Assert.check!(a["eventId"] != b["eventId"], "the second page repeated the first page's event")

    ids = ctx |> AuditLog.fetch!() |> Enum.map(& &1["eventId"])
    index_a = Enum.find_index(ids, &(&1 == a["eventId"]))
    index_b = Enum.find_index(ids, &(&1 == b["eventId"]))

    Assert.check!(
      index_a != nil and index_b == index_a + 1,
      "following the cursor skipped or reordered events"
    )
  end

  defp cursor_opaque(ctx) do
    ensure_events!(ctx, 2)
    cursor = page!(ctx, limit: 1)["nextCursor"]
    Assert.check!(is_binary(cursor), "no cursor was returned to inspect")
    Assert.check!(not readable?(cursor), "the cursor #{inspect(cursor)} discloses a position or count")
  end

  @doc "Whether a cursor reveals a number: plainly, or after base64 or JSON decoding."
  @spec readable?(String.t()) :: boolean()
  def readable?(cursor) do
    decoded =
      [
        Base.decode64(cursor, padding: false),
        Base.url_decode64(cursor, padding: false),
        Base.decode64(cursor),
        Base.url_decode64(cursor)
      ]
      |> Enum.flat_map(fn
        {:ok, value} -> [value]
        :error -> []
      end)

    Enum.any?([cursor | decoded], fn text ->
      Regex.match?(~r/^\s*\d+\s*$/, text) or
        Regex.match?(~r/"(offset|seq|position|page|index)"\s*:\s*\d+/i, text) or
        Regex.match?(~r/^(offset|seq|page|position)[=:]\d+$/i, text)
    end)
  end

  defp cursor_exhausted(ctx) do
    ensure_events!(ctx, 1)
    last = walk_to_last(ctx, nil, 0)

    Assert.check!(
      Map.has_key?(last, "nextCursor"),
      "the last page omits nextCursor; it must be present and null"
    )

    Assert.check!(
      is_nil(last["nextCursor"]),
      "the last page's nextCursor is #{inspect(last["nextCursor"])}, expected null"
    )
  end

  defp walk_to_last(_ctx, _cursor, 60), do: Assert.fail!("the audit log did not end within 60 pages of 200")

  defp walk_to_last(ctx, cursor, pages) do
    body = page!(ctx, if(cursor, do: [limit: 200, cursor: cursor], else: [limit: 200]))

    case body["nextCursor"] do
      next when is_binary(next) and next != "" -> walk_to_last(ctx, next, pages + 1)
      _done -> body
    end
  end

  defp append_only(ctx) do
    ensure_events!(ctx, 1)
    before = AuditLog.fetch!(ctx)
    ensure_events!(ctx, 1)
    later = AuditLog.fetch!(ctx)

    Assert.check!(
      Enum.take(later, length(before)) == before,
      "the earlier part of the log changed after a later operation"
    )
  end
end
