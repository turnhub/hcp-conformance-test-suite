defmodule HcpConformance.Checks.Export do
  @moduledoc """
  GET /v1/export (§3.3.5): the person's own export. It contains everything whose
  existence the person could not otherwise infer (soft-deleted entries included),
  never anything hard-deleted, offers versions and the audit log on request, is
  closed to agents, and is itself audited.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, Fixtures}
  alias HcpConformance.Checks.Entries

  def group, do: "export"

  def checks do
    person = [requires: [:rest, :person]]

    [
      Check.new(
        "export.agents_refused",
        "3.3.5",
        :must,
        "Agents cannot export",
        &agents_refused/1,
        requires: [:rest, :agent]
      ),
      Check.new(
        "export.default_contents",
        "3.3.5",
        :must,
        "The default export includes soft-deleted entries and excludes hard-deleted ones",
        &default_contents/1,
        person
      ),
      Check.new(
        "export.exclude_deleted",
        "3.3.5",
        :must,
        "exclude=deleted omits soft-deleted entries",
        &exclude_deleted/1,
        person
      ),
      Check.new(
        "export.include_versions",
        "3.3.5",
        :must,
        "include=versions adds superseded versions",
        &include_versions/1,
        person
      ),
      Check.new(
        "export.include_audit",
        "3.3.5",
        :must,
        "include=audit adds the person's audit log",
        &include_audit/1,
        person
      ),
      Check.new(
        "export.audited",
        "3.3.5",
        :must,
        "Every export appends preference.exported recording its parameters",
        &audited/1,
        person
      )
    ]
  end

  defp export!(ctx, params \\ []) do
    response =
      Context.request(ctx, :get, Context.url(ctx, :export),
        token: Context.person!(ctx),
        params: params
      )

    Assert.status!(response, 200, "GET /v1/export")
    Assert.json_object!(response, "GET /v1/export")
  end

  # The export's layout beyond "a JSON-LD document" is not fixed, so entries and
  # events are found wherever they sit in the body.
  defp objects(body, match) do
    case body do
      map when is_map(map) ->
        if(match.(map), do: [map], else: []) ++
          Enum.flat_map(Map.values(map), &objects(&1, match))

      list when is_list(list) ->
        Enum.flat_map(list, &objects(&1, match))

      _scalar ->
        []
    end
  end

  defp contains_entry?(body, id), do: objects(body, &(&1["id"] == id)) != []

  defp agents_refused(ctx) do
    response =
      Context.request(ctx, :get, Context.url(ctx, :export), token: Context.agent!(ctx).token)

    Assert.refused!(response, "an agent exporting")
  end

  defp three_entries!(ctx) do
    token = Context.person!(ctx)
    active = Fixtures.create!(ctx, token)
    soft = Fixtures.create!(ctx, token)
    hard = Fixtures.create!(ctx, token)
    Entries.delete!(ctx, token, soft["id"])
    Entries.delete!(ctx, token, hard["id"], hardDelete: true)
    {active, soft, hard}
  end

  defp default_contents(ctx) do
    {active, soft, hard} = three_entries!(ctx)
    body = export!(ctx)
    Assert.check!(contains_entry?(body, active["id"]), "the export omits an active entry")

    Assert.check!(
      contains_entry?(body, soft["id"]),
      "the default export omits a soft-deleted entry"
    )

    Assert.check!(
      not contains_entry?(body, hard["id"]),
      "the export contains a hard-deleted entry"
    )
  end

  defp exclude_deleted(ctx) do
    {active, soft, hard} = three_entries!(ctx)
    body = export!(ctx, exclude: "deleted")
    Assert.check!(contains_entry?(body, active["id"]), "exclude=deleted dropped an active entry")

    Assert.check!(
      not contains_entry?(body, soft["id"]),
      "exclude=deleted still contains a soft-deleted entry"
    )

    Assert.check!(
      not contains_entry?(body, hard["id"]),
      "the export contains a hard-deleted entry"
    )
  end

  defp include_versions(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    Entries.update!(ctx, token, entry["id"], "Second version " <> Context.unique_word(ctx))
    body = export!(ctx, include: "versions")
    form = ctx.envelope_form

    versions =
      body
      |> objects(&(&1["id"] == entry["id"]))
      |> Enum.map(&HcpConformance.Envelope.get(&1, form, ["record", "version"]))

    Assert.check!(
      1 in versions and 2 in versions,
      "include=versions must return version 1 and 2 of an updated entry, found #{inspect(Enum.uniq(versions))}"
    )
  end

  defp include_audit(ctx) do
    Fixtures.create!(ctx, Context.person!(ctx))
    body = export!(ctx, include: "audit")
    events = objects(body, &(is_binary(&1["eventType"]) and is_binary(&1["eventId"])))
    Assert.check!(events != [], "include=audit returned no audit events")
  end

  defp audited(ctx) do
    export!(ctx, include: "audit,versions")

    # await! fails the check when no event records the parameters.
    AuditLog.await!(ctx, "preference.exported (include=audit,versions)", fn event ->
      AuditLog.event?(event, "preference.exported") and is_binary(event["detail"]) and
        String.contains?(event["detail"], "audit") and
        String.contains?(event["detail"], "versions")
    end)
  end
end
