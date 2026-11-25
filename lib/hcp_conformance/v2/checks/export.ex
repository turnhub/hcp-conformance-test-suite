defmodule HcpConformance.V2.Checks.Export do
  @moduledoc """
  Export (§5.4.1): the document and its options. The default carries everything
  whose existence the person could not otherwise infer, withdrawn entries
  included; superseded versions and the audit log are opt-in; hard-deleted
  entries never return.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.Fixtures

  def group, do: "export"

  def checks do
    person = [requires: [:rest, :person]]

    [
      Check.new(
        "export.document",
        "5.4.1",
        :must,
        "An export is a ContextExport document naming its schema, subject, provider, time and options",
        &document/1,
        person
      ),
      Check.new(
        "export.default_contents",
        "5.4.1",
        :must,
        "The default export includes withdrawn entries, each in the entry form, and excludes hard-deleted ones",
        &default_contents/1,
        person
      ),
      Check.new(
        "export.exclude_deleted",
        "9.4.8",
        :must,
        "exclude=deleted omits withdrawn entries",
        &exclude_deleted/1,
        person
      ),
      Check.new(
        "export.include_versions",
        "9.4.8",
        :must,
        "include=versions adds superseded versions",
        &include_versions/1,
        person
      ),
      Check.new(
        "export.include_audit",
        "9.4.8",
        :must,
        "include=audit adds the person's audit log",
        &include_audit/1,
        person
      ),
      Check.new(
        "export.rules",
        "5.4.1",
        :must,
        "The export carries the person's standing rules",
        &rules/1,
        person
      ),
      Check.new(
        "export.audited",
        "5.4.1",
        :must,
        "Every export appends context.exported recording its options",
        &audited/1,
        person
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)

  defp export!(ctx, params \\ []) do
    response =
      Context.request(ctx, :get, Context.url(ctx, :export), token: person(ctx), params: params)

    Assert.status!(response, 200, "GET /v2/export")
    document = Assert.json_object!(response, "GET /v2/export")
    Assert.check!(is_list(document["entries"]), "the export has no entries array")
    document
  end

  defp ids(entries), do: for(%{"id" => id} <- List.wrap(entries), do: id)

  defp document(ctx) do
    document = export!(ctx)

    problems =
      for {false, message} <- [
            {document["type"] == "ContextExport", "type must be ContextExport"},
            {document["schema"] == "https://hcp.example/spec/export/2.0",
             "schema must name this draft's export structure"},
            {is_binary(get_in(document, ["subject", "id"])), "subject.id is required"},
            {is_binary(document["exportedBy"]), "exportedBy is required"},
            {Fixtures.date_time?(document["exportedAt"]), "exportedAt must be a date-time"},
            {is_map(document["options"]), "options is required"},
            {not Map.has_key?(document, "versions") and not Map.has_key?(document, "audit"),
             "versions and audit are present only where requested"}
          ],
          do: message

    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  defp default_contents(ctx) do
    kept = Fixtures.create!(ctx, person(ctx))
    withdrawn = Fixtures.create!(ctx, person(ctx))
    erased = Fixtures.create!(ctx, person(ctx))
    Assert.status!(Fixtures.delete(ctx, person(ctx), withdrawn["id"]), 200, "the withdrawal")

    Assert.status!(
      Fixtures.delete(ctx, person(ctx), erased["id"], params: [hardDelete: true]),
      [200, 204],
      "the hard deletion"
    )

    entries = export!(ctx)["entries"]
    exported = ids(entries)

    Assert.check!(kept["id"] in exported, "the export lacks an active entry")

    Assert.check!(
      withdrawn["id"] in exported,
      "the default export lacks a withdrawn entry, which the person could not otherwise know is held"
    )

    Assert.check!(erased["id"] not in exported, "the export returned a hard-deleted entry")

    statuses =
      for %{"id" => id} = entry <- entries,
          id in [kept["id"], withdrawn["id"]],
          do: get_in(entry, ["record", "status"])

    Assert.check!(
      Enum.sort(statuses) == ["active", "deleted"],
      "every exported entry carries its status"
    )
  end

  defp exclude_deleted(ctx) do
    withdrawn = Fixtures.create!(ctx, person(ctx))
    Assert.status!(Fixtures.delete(ctx, person(ctx), withdrawn["id"]), 200, "the withdrawal")
    document = export!(ctx, exclude: "deleted")

    Assert.check!(
      withdrawn["id"] not in ids(document["entries"]),
      "exclude=deleted still returned a withdrawn entry"
    )

    Assert.check!(
      get_in(document, ["options", "excludeDeleted"]) == true,
      "options must record excludeDeleted"
    )
  end

  defp include_versions(ctx) do
    created = Fixtures.create!(ctx, person(ctx))

    Assert.status!(
      Fixtures.revise(ctx, person(ctx), created["id"], %{"expectedVersion" => 1}),
      201,
      "the revision"
    )

    document = export!(ctx, include: "versions")
    current = Enum.find(document["entries"], &(&1["id"] == created["id"]))

    Assert.check!(
      get_in(current, ["record", "version"]) == 2,
      "entries must hold the current version"
    )

    superseded =
      for %{"id" => id} = entry <- List.wrap(document["versions"]),
          id == created["id"],
          do: get_in(entry, ["record", "version"])

    Assert.check!(
      superseded == [1],
      "versions must hold the superseded version 1, got #{inspect(superseded)}"
    )
  end

  defp include_audit(ctx) do
    Fixtures.create!(ctx, person(ctx))
    audit = export!(ctx, include: "audit")["audit"]
    Assert.check!(is_list(audit) and audit != [], "include=audit did not add the audit log")

    Assert.check!(
      Enum.all?(audit, &(is_map(&1) and is_binary(&1["eventType"]))),
      "audit must hold events in the log entry structure"
    )
  end

  defp rules(ctx) do
    body = %{"operators" => ["export-#{Context.random_word(8)}.conformance.hcp.example"]}

    response =
      Context.request(ctx, :post, Context.url(ctx, :rules), token: person(ctx), json: body)

    Assert.status!(response, 201, "POST /v2/rules")
    id = Assert.json_object!(response, "POST /v2/rules")["ruleId"]

    try do
      exported = for %{"ruleId" => id} <- List.wrap(export!(ctx)["rules"]), do: id
      Assert.check!(id in exported, "the export does not carry a standing rule the person set")
    after
      Context.request(ctx, :delete, Context.url(ctx, :rules) <> "/" <> to_string(id),
        token: person(ctx)
      )
    end
  end

  defp audited(ctx) do
    before = ctx |> AuditLog.fetch!() |> Enum.count(&AuditLog.event?(&1, "context.exported"))
    export!(ctx, exclude: "deleted")

    AuditLog.await!(
      ctx,
      "context.exported recording its options",
      &(AuditLog.event?(&1, "context.exported") and
          get_in(&1, ["data", "options", "excludeDeleted"]) == true)
    )

    count = ctx |> AuditLog.fetch!() |> Enum.count(&AuditLog.event?(&1, "context.exported"))
    Assert.check!(count == before + 1, "one export appended #{count - before} context.exported")
  end
end
