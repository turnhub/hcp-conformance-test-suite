defmodule HcpConformance.V2.Checks.Audit do
  @moduledoc """
  The audit log (§8): the structure of an event and the participants it names
  (§3.9), cursor pagination (§9.5), and append-only behaviour. That a Context
  Client cannot read it is checked with the rest of the governance plane.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.Checks.Audit, as: V1Audit
  alias HcpConformance.V2.Fixtures

  @event_types ~w(context.created context.read context.revised context.recategorized context.restricted
                  context.withdrawn context.hardDeleted context.confirmed context.exported context.imported
                  context.shared context.expired context.credentialStatus grant.issued grant.revoked grant.expired
                  delegation.established delegation.ended rule.set rule.removed directive.set directive.removed
                  conflict.detected conflict.proposed conflict.resolved revocation.notified)
  @roles ~w(management-client context-client authorization-service hcp-provider)

  def group, do: "audit"

  def checks do
    person = [requires: [:rest, :person]]

    [
      Check.new(
        "audit.event_structure",
        "8.2",
        :must,
        "Every event follows the log entry structure, with a registered event type",
        &event_structure/1,
        person
      ),
      Check.new(
        "audit.participants",
        "3.9",
        :must,
        "Every event names its initiator by role and its provider, and the Client Operator where a client initiated it",
        &participants/1,
        person
      ),
      Check.new(
        "audit.pagination",
        "9.5",
        :must,
        "limit bounds a page, and nextCursor continues without gaps or repeats",
        &pagination/1,
        person
      ),
      Check.new(
        "audit.cursor_opaque",
        "9.5",
        :must,
        "Cursors are opaque: not a bare sequence number or offset",
        &cursor_opaque/1,
        person
      ),
      Check.new(
        "audit.cursor_exhausted",
        "9.5",
        :must,
        "The last page carries nextCursor: null",
        &cursor_exhausted/1,
        person
      ),
      Check.new(
        "audit.append_only",
        "8",
        :must,
        "Earlier events are never changed or removed by later operations",
        &append_only/1,
        person
      )
    ]
  end

  defp page!(ctx, params) do
    response =
      Context.request(ctx, :get, Context.url(ctx, :audit),
        token: Context.person!(ctx),
        params: params
      )

    Assert.status!(response, 200, "GET /v2/audit")
    body = Assert.json_object!(response, "GET /v2/audit")
    Assert.check!(is_list(body["events"]), "the body must carry an events array")
    body
  end

  defp ensure_events!(ctx, count),
    do: for(_ <- 1..count, do: Fixtures.create!(ctx, Context.person!(ctx)))

  defp violations!(ctx, problems) do
    ensure_events!(ctx, 1)
    events = AuditLog.fetch!(ctx)
    Assert.check!(events != [], "the audit log is empty after an entry was created")

    found =
      events
      |> Enum.flat_map(fn event ->
        for {false, message} <- problems.(event), do: "#{event["eventType"]}: #{message}"
      end)
      |> Enum.uniq()

    {shown, rest} = Enum.split(found, 5)
    suffix = if rest == [], do: "", else: " (and #{length(rest)} more)"
    Assert.check!(found == [], Enum.join(shown, "; ") <> suffix)
  end

  defp event_structure(ctx) do
    violations!(ctx, fn event ->
      [
        {Fixtures.urn_uuid?(event["eventId"]), "eventId must be a urn:uuid"},
        {event["eventType"] in @event_types, "not a registered event type"},
        {Fixtures.date_time?(event["timestamp"]), "timestamp must be a date-time"},
        {is_map(event["participants"]), "participants is required"},
        {is_nil(event["data"]) or is_map(event["data"]), "data must be an object"},
        {not Map.has_key?(event, "actorType"), "v1's actorType is replaced by participants"}
      ]
    end)
  end

  defp participants(ctx) do
    violations!(ctx, fn event ->
      participants = event["participants"] || %{}
      role = get_in(participants, ["initiator", "role"])
      client? = role in ["management-client", "context-client"]

      [
        {role in @roles, "initiator.role #{inspect(role)} is not one of #{inspect(@roles)}"},
        {is_binary(get_in(participants, ["initiator", "id"])), "initiator.id is required"},
        {is_binary(get_in(participants, ["provider", "id"])), "provider.id is required"},
        {not client? or is_binary(get_in(participants, ["clientOperator", "id"])),
         "clientOperator is required where the initiator is an HCP Client"}
      ]
    end)
  end

  defp pagination(ctx) do
    ensure_events!(ctx, 3)
    first = page!(ctx, limit: 1)

    Assert.check!(
      length(first["events"]) == 1,
      "limit=1 returned #{length(first["events"])} events"
    )

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
    ids = ctx |> AuditLog.fetch!() |> Enum.map(& &1["eventId"])
    index = Enum.find_index(ids, &(&1 == a["eventId"]))

    Assert.check!(
      index != nil and Enum.at(ids, index + 1) == b["eventId"],
      "following the cursor skipped, repeated or reordered events"
    )
  end

  defp cursor_opaque(ctx) do
    ensure_events!(ctx, 2)
    cursor = page!(ctx, limit: 1)["nextCursor"]
    Assert.check!(is_binary(cursor), "no cursor was returned to inspect")

    Assert.check!(
      not V1Audit.readable?(cursor),
      "the cursor #{inspect(cursor)} discloses a position or count"
    )
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

  defp walk_to_last(_ctx, _cursor, 60),
    do: Assert.fail!("the audit log did not end within 60 pages of 200")

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
