defmodule HcpConformance.V2.Checks.Entries do
  @moduledoc """
  The entry (§4.2) through the context operations of the HTTP Binding (§5.2,
  §9.4): create, get, revise, withdraw and hard delete as a Management Client,
  and what a Context Client receives instead of the stored entry: a disclosure
  under a grant-scoped `ref` (§7.4), usable until a stated time (§7.6).
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.{Checks.Discovery, Fixtures, Target}

  @declarations ~w(person-declared model-inferred issuer-attested)
  @assurances ~w(unverified authenticated cryptographically-verified)
  @statuses ~w(active deprecated conflicted expired revoked suspended deleted)
  @forged "urn:uuid:00000000-0000-4000-8000-00000000f09d"

  def group, do: "entries"

  def checks do
    person = [requires: [:rest, :person]]
    agent = [requires: [:rest, :person, :agent]]
    hook = [requires: [:rest, :person, :hook]]

    [
      Check.new(
        "entries.create",
        "9.4.3",
        :must,
        "POST /v2/entries creates the entry and assigns its id, status and version",
        &create/1,
        person
      ),
      Check.new(
        "entries.shape",
        "4.2",
        :must,
        "A created entry carries every required field of the entry, with values from the specification's vocabularies",
        &shape/1,
        person
      ),
      Check.new(
        "entries.provider_sets_provenance",
        "3.5",
        :must,
        "Provenance the provider sets is never taken from the request",
        &provider_sets_provenance/1,
        person
      ),
      Check.new(
        "entries.declared_assurance",
        "3.7",
        :must,
        "A person-declared entry written by a Context Client is recorded as unverified",
        &declared_assurance/1,
        agent
      ),
      Check.new(
        "entries.preserves_unknown_members",
        "4.2",
        :must,
        "Members of an entry the specification does not define are preserved",
        &preserves_unknown/1,
        person
      ),
      Check.new(
        "entries.inferred_requires_confidence",
        "5.2.3",
        :must,
        "A model-inferred write without confidence is rejected with 422 malformed-request",
        &inferred_requires_confidence/1,
        person
      ),
      Check.new(
        "entries.confidence_only_inferred",
        "5.2.3",
        :must,
        "A write with confidence on an entry that is not model-inferred is rejected with 422 malformed-request",
        &confidence_only_inferred/1,
        person
      ),
      Check.new(
        "entries.inferred_requires_profile",
        "18.1",
        :must,
        "An implementation that accepts model-inferred entries lists the Memory Manager Profile",
        &inferred_requires_profile/1,
        person
      ),
      Check.new(
        "entries.issuer_attested_refused",
        "3.7",
        :must,
        "An issuer-attested write from a client no issuer authorized is refused with 403 scope-denied",
        &issuer_attested_refused/1,
        agent
      ),
      Check.new(
        "entries.unknown_schema",
        "4.2",
        :must,
        "A write naming a schema the provider does not accept is rejected with 422 malformed-request",
        &unknown_schema/1,
        person
      ),
      Check.new(
        "entries.unknown_category",
        "4.5",
        :must,
        "A write naming a category the provider does not hold is rejected with 422 malformed-request",
        &unknown_category/1,
        person
      ),
      Check.new(
        "entries.required_fields",
        "5.2.3",
        :must,
        "A write missing assertion.declarationType or classification.categories is rejected with 422 malformed-request",
        &required_fields/1,
        person
      ),
      Check.new(
        "entries.created_audited",
        "8.1",
        :must,
        "Creating an entry appends context.created",
        &created_audited/1,
        person
      ),
      Check.new(
        "entries.get",
        "9.4.2",
        :must,
        "GET /v2/entries/{entryId} returns the entry inside a result with a retrievalId and a minimization report of none",
        &get/1,
        person
      ),
      Check.new(
        "entries.get_requires_purpose",
        "5.2.2",
        :must,
        "GET /v2/entries/{entryId} without a purpose is refused",
        &get_requires_purpose/1,
        person
      ),
      Check.new(
        "entries.get_audited",
        "5.2.2",
        :must,
        "Reading an entry appends context.read with the stated purpose, naming the entry",
        &get_audited/1,
        person
      ),
      Check.new(
        "entries.revise",
        "9.4.4",
        :must,
        "A revision answers 201, increments record.version by one and keeps the id",
        &revise/1,
        person
      ),
      Check.new(
        "entries.revise_version_conflict",
        "5.2.4",
        :must,
        "A revision naming a stale expectedVersion fails with 409 version-conflict and changes nothing",
        &revise_version_conflict/1,
        person
      ),
      Check.new(
        "entries.get_version",
        "5.2.2",
        :must,
        "GET with ?version=n returns that version of the entry",
        &get_version/1,
        person
      ),
      Check.new(
        "entries.revised_audited",
        "8.1",
        :must,
        "A revision appends context.revised with the new version and the reason",
        &revised_audited/1,
        person
      ),
      Check.new(
        "entries.withdraw",
        "9.4.5",
        :must,
        "DELETE marks the entry deleted, answers with the withdrawal result, and the person still sees it",
        &withdraw/1,
        person
      ),
      Check.new(
        "entries.withdrawn_hidden",
        "5.2.5",
        :must,
        "A withdrawn entry is hidden from Context Clients at once",
        &withdrawn_hidden/1,
        agent
      ),
      Check.new(
        "entries.withdrawn_audited",
        "8.1",
        :must,
        "A withdrawal appends context.withdrawn",
        &withdrawn_audited/1,
        person
      ),
      Check.new(
        "entries.hard_delete",
        "5.4.2",
        :must,
        "DELETE ?hardDelete=true removes the entry permanently for a Management Client",
        &hard_delete/1,
        person
      ),
      Check.new(
        "entries.hard_delete_audited",
        "8.1",
        :must,
        "A hard deletion appends context.hardDeleted",
        &hard_delete_audited/1,
        person
      ),
      Check.new(
        "entries.hard_delete_governance",
        "5.4.2",
        :must,
        "A Context Client cannot hard-delete: the attempt fails with 403 scope-denied",
        &hard_delete_governance/1,
        agent
      ),
      Check.new(
        "entries.disclosure",
        "7.4",
        :must,
        "A Context Client receives a disclosure: ref, content, standing and useUntil, without id, subject or record",
        &disclosure/1,
        agent
      ),
      Check.new(
        "entries.ref_opaque",
        "7.4",
        :must,
        "A disclosure's ref does not reveal the entry's id",
        &ref_opaque/1,
        agent
      ),
      Check.new(
        "entries.ref_grant_scoped",
        "7.4",
        :must,
        "A ref differs under every grant, and fails with 403 scope-denied when presented under another",
        &ref_grant_scoped/1,
        hook
      ),
      Check.new(
        "entries.nonexistent_is_403",
        "5.2.2",
        :must,
        "A Context Client naming an entry that does not exist gets 403 scope-denied, not 404",
        &nonexistent/1,
        agent
      ),
      Check.new(
        "entries.use_until",
        "7.6",
        :must,
        "useUntil is in the future and within the ceiling: one hour for a client with no notification endpoint",
        &use_until/1,
        agent
      ),
      Check.new(
        "entries.write_needs_write",
        "6.1",
        :must,
        "A client holding only read cannot create an entry",
        &write_needs_write/1,
        hook
      ),
      Check.new(
        "entries.category_outside_grant",
        "5.2.3",
        :must,
        "A create naming a category the grant cannot write fails with 403 scope-denied",
        &category_outside_grant/1,
        requires: [:rest, :person, :agent, :second_category]
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)
  defp agent(ctx), do: Context.agent!(ctx).token

  defp create(ctx) do
    entry = Fixtures.create!(ctx, person(ctx))
    record = entry["record"] || %{}

    Assert.check!(
      Fixtures.urn_uuid?(entry["id"]),
      "id must be a urn:uuid, got #{inspect(entry["id"])}"
    )

    Assert.check!(
      record["status"] == "active",
      "record.status must be active, got #{inspect(record["status"])}"
    )

    Assert.check!(
      record["version"] == 1,
      "record.version must start at 1, got #{inspect(record["version"])}"
    )
  end

  defp shape(ctx) do
    entry = Fixtures.create!(ctx, person(ctx))
    problems = shape_problems(entry)
    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  @doc "What is wrong with an entry as the provider holds it (§4.2), as a list of messages."
  @spec shape_problems(map()) :: [String.t()]
  def shape_problems(entry) do
    provenance = get_in(entry, ["record", "provenance"]) || %{}
    client = provenance["submittedByClient"]
    categories = get_in(entry, ["classification", "categories"])

    for {false, message} <- [
          {entry["@context"] == ["https://hcp.example/contexts/v2"],
           "@context must be the fixed constant"},
          {entry["schema"] == Fixtures.entry_schema(),
           "schema must be #{Fixtures.entry_schema()}"},
          {is_list(entry["type"]) and "ContextEntry" in entry["type"],
           "type must include ContextEntry"},
          {is_binary(get_in(entry, ["subject", "id"])), "subject.id is required"},
          {is_binary(get_in(entry, ["content", "profile"])), "content.profile is required"},
          {get_in(entry, ["assertion", "declarationType"]) in @declarations,
           "assertion.declarationType must be one of #{inspect(@declarations)}"},
          {is_list(categories) and categories != [] and Enum.uniq(categories) == categories,
           "classification.categories must be a non-empty array without duplicates"},
          {get_in(entry, ["record", "status"]) in @statuses,
           "record.status must be a lifecycle state"},
          {is_integer(get_in(entry, ["record", "version"])), "record.version must be an integer"},
          {is_binary(get_in(provenance, ["assertedBy", "id"])),
           "record.provenance.assertedBy.id is required"},
          {get_in(provenance, ["assertedBy", "assurance"]) in @assurances,
           "record.provenance.assertedBy.assurance must be one of #{inspect(@assurances)}"},
          {Fixtures.date_time?(provenance["assertedAt"]),
           "record.provenance.assertedAt must be a date-time"},
          {is_binary(provenance["source"]), "record.provenance.source is required"},
          {is_map(client) and is_binary(client["id"]) and is_map(client["operator"]),
           "record.provenance.submittedByClient must name the client and its operator"},
          {is_binary(provenance["authorizedUnder"]),
           "record.provenance.authorizedUnder is required"},
          {is_binary(provenance["recordedByProvider"]),
           "record.provenance.recordedByProvider is required"},
          {Fixtures.date_time?(provenance["recordedAt"]),
           "record.provenance.recordedAt must be a date-time"}
        ],
        do: message
  end

  defp provider_sets_provenance(ctx) do
    forged = %{
      "record" => %{
        "provenance" => %{
          "assertedBy" => %{"assurance" => "cryptographically-verified"},
          "submittedByClient" => %{
            "id" => @forged,
            "name" => "Forged",
            "operator" => %{"id" => @forged, "name" => "Forged"}
          },
          "authorizedUnder" => @forged,
          "recordedByProvider" => @forged,
          "recordedAt" => "2001-01-01T00:00:00Z",
          "confirmations" => [
            %{
              "disposition" => "confirmed",
              "confirmedBy" => %{"id" => @forged},
              "confirmedAt" => "2001-01-01T00:00:00Z"
            }
          ]
        }
      }
    }

    response = Fixtures.post(ctx, person(ctx), Fixtures.entry_body(ctx, merge: forged))

    # Refusing the forged members outright is as good as ignoring them.
    if response.status == 201 do
      entry = Assert.json_object!(response, "POST /v2/entries")
      if is_binary(entry["id"]), do: Context.track_entry(ctx, entry["id"])
      provenance = get_in(entry, ["record", "provenance"]) || %{}

      taken =
        for {false, member} <- [
              {get_in(provenance, ["assertedBy", "assurance"]) != "cryptographically-verified",
               "assertedBy.assurance"},
              {get_in(provenance, ["submittedByClient", "id"]) != @forged, "submittedByClient"},
              {provenance["authorizedUnder"] != @forged, "authorizedUnder"},
              {provenance["recordedByProvider"] != @forged, "recordedByProvider"},
              {provenance["recordedAt"] != "2001-01-01T00:00:00Z", "recordedAt"},
              {List.wrap(provenance["confirmations"]) == [], "confirmations"}
            ],
            do: member

      Assert.check!(taken == [], "taken from the request: " <> Enum.join(taken, ", "))
    else
      Assert.refused!(response, "a create carrying provider-set provenance")
    end
  end

  # The person finds an entry a client wrote by its unique word, and reads it whole.
  defp as_person!(ctx, word) do
    result = Fixtures.query!(ctx, person(ctx), %{"query" => word, "maxEntries" => 20})

    case Enum.filter(result["entries"], &(is_map(&1) and is_binary(&1["id"]))) do
      [entry | _] ->
        entry

      [] ->
        Assert.fail!(
          "the person's query did not find the entry a Context Client had just written"
        )
    end
  end

  defp declared_assurance(ctx) do
    word = Context.unique_word(ctx)
    Fixtures.create!(ctx, agent(ctx), value: "I prefer " <> word)
    assurance = get_in(as_person!(ctx, word), ["record", "provenance", "assertedBy", "assurance"])

    Assert.check!(
      assurance == "unverified",
      "a Context Client's person-declared entry was recorded as #{inspect(assurance)}; " <>
        "the declaration type a caller supplies does not establish that the person stated it"
    )
  end

  defp preserves_unknown(ctx) do
    member = "https://conformance.hcp.example/extension"
    created = Fixtures.create!(ctx, person(ctx), merge: %{member => %{"kept" => ctx.nonce}})
    entry = Fixtures.get!(ctx, person(ctx), created["id"])

    Assert.check!(
      entry[member] == %{"kept" => ctx.nonce},
      "the member #{member} was not preserved: #{inspect(entry[member])}"
    )
  end

  defp rejected!(ctx, opts, what) do
    ctx
    |> Fixtures.post(person(ctx), Fixtures.entry_body(ctx, opts))
    |> Assert.problem!(422, "malformed-request", what)
  end

  defp inferred_requires_confidence(ctx) do
    rejected!(
      ctx,
      [declaration_type: "model-inferred", asserted_by: "model:hcp-conformance"],
      "a model-inferred write without confidence"
    )
  end

  defp confidence_only_inferred(ctx),
    do: rejected!(ctx, [confidence: "high"], "a person-declared write carrying confidence")

  defp inferred_requires_profile(ctx) do
    body =
      Fixtures.entry_body(ctx,
        declaration_type: "model-inferred",
        confidence: "medium",
        asserted_by: "model:hcp-conformance"
      )

    response = Fixtures.post(ctx, person(ctx), body)

    if response.status in 200..299 do
      if is_map(response.json) and is_binary(response.json["id"]),
        do: Context.track_entry(ctx, response.json["id"])

      Assert.check!(
        Discovery.memory_manager() in List.wrap((ctx.discovery || %{})["conformsTo"]),
        "a model-inferred entry was accepted, but conformsTo does not list the Memory Manager Profile"
      )
    else
      Assert.refused!(
        response,
        "a model-inferred write to an implementation that does not accept them"
      )
    end
  end

  defp issuer_attested_refused(ctx) do
    body =
      Fixtures.entry_body(ctx,
        declaration_type: "issuer-attested",
        asserted_by: "https://issuer.conformance.hcp.example"
      )

    ctx
    |> Fixtures.post(agent(ctx), body)
    |> Assert.problem!(
      403,
      "scope-denied",
      "an issuer-attested write by a client no issuer authorized"
    )
  end

  defp unknown_schema(ctx),
    do:
      rejected!(
        ctx,
        [merge: %{"schema" => "https://conformance.hcp.example/spec/entry/unknown"}],
        "a write naming an unknown schema"
      )

  defp unknown_category(ctx),
    do:
      rejected!(
        ctx,
        [categories: ["https://conformance.hcp.example/categories/not-held"]],
        "a write naming a category not held"
      )

  defp required_fields(ctx) do
    rejected!(
      ctx,
      [drop: [["assertion", "declarationType"]]],
      "a write without assertion.declarationType"
    )

    rejected!(
      ctx,
      [drop: [["classification", "categories"]]],
      "a write without classification.categories"
    )
  end

  defp created_audited(ctx) do
    entry = Fixtures.create!(ctx, person(ctx))

    [event | _] =
      AuditLog.await!(
        ctx,
        "context.created",
        &AuditLog.event?(&1, "context.created", entryId: entry["id"])
      )

    Assert.check!(
      get_in(event, ["data", "version"]) == 1,
      "context.created must record version 1 in data"
    )
  end

  defp get(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    response = Fixtures.get(ctx, person(ctx), created["id"])
    Assert.status!(response, 200, "GET /v2/entries/{entryId}")
    result = Assert.json_object!(response, "GET /v2/entries/{entryId}")

    Assert.check!(
      get_in(result, ["entry", "id"]) == created["id"],
      "the result's entry is not the entry asked for"
    )

    Assert.check!(Fixtures.urn_uuid?(result["retrievalId"]), "retrievalId must be a urn:uuid")

    Assert.check!(
      get_in(result, ["minimization", "method"]) == "none",
      "a get-entry result reports minimization.method as none"
    )

    Assert.check!(Fixtures.date_time?(result["timestamp"]), "timestamp must be a date-time")
  end

  defp get_requires_purpose(ctx) do
    created = Fixtures.create!(ctx, person(ctx))

    response =
      Context.request(ctx, :get, Context.entry_url(ctx, created["id"]), token: person(ctx))

    Assert.refused!(response, "GET /v2/entries/{entryId} without a purpose")
  end

  defp get_audited(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    Fixtures.get!(ctx, person(ctx), created["id"])

    # What a Context Client was disclosed is checked by query.audited; for the
    # person's own read, the event names the entry one way or the other.
    match = fn event ->
      AuditLog.event?(event, "context.read", purpose: Target.purpose()) and
        (event["entryId"] == created["id"] or
           Enum.any?(
             List.wrap(event["disclosed"]),
             &(is_map(&1) and &1["entryId"] == created["id"])
           ))
    end

    AuditLog.await!(ctx, "context.read naming the purpose and the entry read", match, read?: true)
  end

  defp revised!(ctx, created) do
    response = Fixtures.revise(ctx, person(ctx), created["id"], %{"expectedVersion" => 1})
    Assert.status!(response, 201, "POST /v2/entries/{entryId}/revisions")
    Assert.json_object!(response, "POST /v2/entries/{entryId}/revisions")
  end

  defp revise(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    revised = revised!(ctx, created)
    Assert.check!(revised["id"] == created["id"], "a revision must keep the entry's id")

    Assert.check!(
      get_in(revised, ["record", "version"]) == 2,
      "record.version must be 2 after one revision"
    )

    Assert.check!(
      get_in(revised, ["content", "value"]) != get_in(created, ["content", "value"]),
      "the content was not replaced"
    )
  end

  defp revise_version_conflict(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    revised!(ctx, created)
    response = Fixtures.revise(ctx, person(ctx), created["id"], %{"expectedVersion" => 1})

    Assert.problem!(
      response,
      409,
      "version-conflict",
      "a revision naming a stale expectedVersion"
    )

    current = Fixtures.get!(ctx, person(ctx), created["id"])

    Assert.check!(
      get_in(current, ["record", "version"]) == 2,
      "the refused revision changed the entry"
    )
  end

  defp get_version(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    revised!(ctx, created)
    first = Fixtures.get!(ctx, person(ctx), created["id"], version: 1)

    Assert.check!(
      get_in(first, ["record", "version"]) == 1,
      "?version=1 did not return version 1"
    )

    Assert.check!(
      first["content"] == created["content"],
      "version 1 no longer carries its original content"
    )
  end

  defp revised_audited(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    revised!(ctx, created)

    [event | _] =
      AuditLog.await!(
        ctx,
        "context.revised",
        &AuditLog.event?(&1, "context.revised", entryId: created["id"])
      )

    data = event["data"] || %{}
    Assert.check!(data["version"] == 2, "context.revised must record the new version in data")

    Assert.check!(
      data["reason"] == "HCP conformance check",
      "context.revised must record the reason in data"
    )
  end

  defp withdraw(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    response = Fixtures.delete(ctx, person(ctx), created["id"])
    Assert.status!(response, 200, "DELETE /v2/entries/{entryId}")
    result = Assert.json_object!(response, "DELETE /v2/entries/{entryId}")

    Assert.check!(
      result["entryId"] == created["id"],
      "the result must name the entry as the caller named it"
    )

    Assert.check!(result["status"] == "deleted", "the result's status must be deleted")
    Assert.check!(Fixtures.date_time?(result["timestamp"]), "the result must carry a timestamp")

    held = Fixtures.get!(ctx, person(ctx), created["id"])

    Assert.check!(
      get_in(held, ["record", "status"]) == "deleted",
      "the person must still see the withdrawn entry, as deleted"
    )
  end

  defp withdrawn_hidden(ctx) do
    word = Context.unique_word(ctx)
    disclosed = Fixtures.create!(ctx, agent(ctx), value: "I prefer " <> word)
    response = Fixtures.delete(ctx, agent(ctx), disclosed["ref"])
    Assert.status!(response, 200, "DELETE /v2/entries/{ref} by a Context Client")
    result = Assert.json_object!(response, "DELETE /v2/entries/{ref}")

    Assert.check!(
      result["ref"] == disclosed["ref"] and not Map.has_key?(result, "entryId"),
      "a Context Client names an entry by its ref and receives the ref back, never the id"
    )

    Assert.problem!(
      Fixtures.get(ctx, agent(ctx), disclosed["ref"]),
      403,
      "scope-denied",
      "reading a withdrawn entry by ref"
    )

    Assert.check!(
      Fixtures.found(ctx, agent(ctx), word) == [],
      "a query still returned the withdrawn entry"
    )
  end

  defp withdrawn_audited(ctx) do
    created = Fixtures.create!(ctx, person(ctx))

    Assert.status!(
      Fixtures.delete(ctx, person(ctx), created["id"]),
      200,
      "DELETE /v2/entries/{entryId}"
    )

    AuditLog.await!(
      ctx,
      "context.withdrawn",
      &AuditLog.event?(&1, "context.withdrawn", entryId: created["id"])
    )
  end

  defp hard_delete!(ctx, id) do
    response = Fixtures.delete(ctx, person(ctx), id, params: [hardDelete: true])
    Assert.status!(response, [200, 204], "DELETE /v2/entries/{entryId}?hardDelete=true")
  end

  defp hard_delete(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    hard_delete!(ctx, created["id"])
    Assert.refused!(Fixtures.get(ctx, person(ctx), created["id"]), "reading a hard-deleted entry")
  end

  defp hard_delete_audited(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    hard_delete!(ctx, created["id"])

    AuditLog.await!(
      ctx,
      "context.hardDeleted",
      &AuditLog.event?(&1, "context.hardDeleted", entryId: created["id"])
    )
  end

  defp hard_delete_governance(ctx) do
    disclosed = Fixtures.create!(ctx, agent(ctx))
    response = Fixtures.delete(ctx, agent(ctx), disclosed["ref"], params: [hardDelete: true])
    Assert.problem!(response, 403, "scope-denied", "a hard deletion by a Context Client")
  end

  defp disclosed!(ctx) do
    word = Context.unique_word(ctx)
    entry = Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)

    case Fixtures.found(ctx, agent(ctx), word) do
      [disclosure] when is_map(disclosure) ->
        {entry, disclosure}

      other ->
        Assert.fail!(
          "expected the Context Client's query to return the one entry just written, got #{length(other)}"
        )
    end
  end

  defp disclosure(ctx) do
    {_entry, disclosure} = disclosed!(ctx)
    standing = disclosure["standing"] || %{}
    withheld = Enum.filter(~w(id subject record), &Map.has_key?(disclosure, &1))

    problems =
      for {false, message} <- [
            {withheld == [],
             "it carries #{Enum.join(withheld, ", ")}, which a disclosure withholds"},
            {is_binary(disclosure["ref"]) and disclosure["ref"] != "", "ref is required"},
            {is_integer(disclosure["version"]), "version is required"},
            {is_map(disclosure["content"]) and is_map(disclosure["assertion"]),
             "content and assertion are disclosed as stored"},
            {get_in(disclosure, ["classification", "categories"]) == [ctx.primary_category],
             "classification.categories lists the categories the grant covers"},
            {standing["assurance"] in @assurances,
             "standing.assurance must be one of #{inspect(@assurances)}"},
            {is_boolean(standing["confirmed"]), "standing.confirmed must be a boolean"},
            {Fixtures.date_time?(disclosure["useUntil"]), "useUntil must be a date-time"}
          ],
          do: message

    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  defp ref_opaque(ctx) do
    {entry, disclosure} = disclosed!(ctx)
    ref = to_string(disclosure["ref"])
    uuid = String.replace_prefix(entry["id"], "urn:uuid:", "")

    Assert.check!(
      not String.contains?(ref, uuid) and not String.contains?(ref, String.replace(uuid, "-", "")),
      "the ref #{inspect(ref)} contains the entry's id"
    )

    decoded =
      for {:ok, text} <- [
            Base.url_decode64(ref, padding: false),
            Base.decode64(ref, padding: false)
          ],
          do: text

    Assert.check!(
      not Enum.any?(decoded, &String.contains?(&1, uuid)),
      "the ref decodes to the entry's id"
    )
  end

  defp ref_grant_scoped(ctx) do
    word = Context.unique_word(ctx)
    Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)
    first = Context.issue_grant!(ctx, actions: ["read"])
    second = Context.issue_grant!(ctx, actions: ["read"])
    [a] = Fixtures.found(ctx, first.token, word)
    [b] = Fixtures.found(ctx, second.token, word)

    Assert.check!(
      a["ref"] != b["ref"],
      "two grants were given the same ref #{inspect(a["ref"])} for one entry"
    )

    Assert.status!(
      Fixtures.get(ctx, first.token, a["ref"]),
      200,
      "reading an entry by the ref disclosed under the same grant"
    )

    Assert.problem!(
      Fixtures.get(ctx, second.token, a["ref"]),
      403,
      "scope-denied",
      "a ref presented under another grant"
    )
  end

  defp nonexistent(ctx) do
    response = Fixtures.get(ctx, agent(ctx), "r_" <> Context.random_word(14))
    Assert.problem!(response, 403, "scope-denied", "GET for an entry that does not exist")
  end

  defp use_until(ctx) do
    {_entry, disclosure} = disclosed!(ctx)
    Assert.check!(Fixtures.date_time?(disclosure["useUntil"]), "useUntil must be a date-time")
    {:ok, until, _offset} = DateTime.from_iso8601(disclosure["useUntil"])
    seconds = DateTime.diff(until, DateTime.utc_now())
    # The suite's own clients register no notification endpoint, so a copy is
    # usable for an hour at most; a client supplied by token may have one.
    ceiling = if Context.has?(ctx, :hook), do: 3_600, else: 30 * 86_400

    Assert.check!(
      seconds > -120,
      "useUntil #{disclosure["useUntil"]} is already past for an entry that has not lapsed"
    )

    Assert.check!(
      seconds <= ceiling + 120,
      "useUntil is #{seconds} s after disclosure, above the ceiling of #{ceiling} s"
    )
  end

  defp write_needs_write(ctx) do
    grant = Context.issue_grant!(ctx, actions: ["read"])
    response = Fixtures.post(ctx, grant.token, Fixtures.entry_body(ctx))
    Assert.problem!(response, 403, "scope-denied", "a create by a read-only client")
  end

  defp category_outside_grant(ctx) do
    response =
      Fixtures.post(ctx, agent(ctx), Fixtures.entry_body(ctx, categories: [ctx.second_category]))

    Assert.problem!(
      response,
      403,
      "scope-denied",
      "a create in a category the grant cannot write"
    )
  end
end
