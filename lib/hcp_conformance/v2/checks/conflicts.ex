defmodule HcpConformance.V2.Checks.Conflicts do
  @moduledoc """
  Conflicts between entries (§4.7) and the Memory Manager Profile (§15).

  Two entries conflict when a `contradicts` relationship links them. A client
  may assert one with a write, so the consequences Core fixes can be checked
  without knowing how a provider finds conflicts: which entry is quarantined is
  decided by standing (§4.7.1), a quarantined entry is withheld from Context
  Clients, and only the person resolves a conflict, by rejecting, accepting or
  revising (§4.7.3).

  How a provider finds conflicts itself is its own method, declared in
  discovery (§15.2). The suite cannot require a method to find a given pair, so
  it writes the plainest contradiction it can, a statement and its negation,
  and checks what must follow where the provider finds it. Where the provider
  does not, those checks do not apply. One thing holds for every method: a
  shared dimension alone is not a conflict.

  The checks that write an inference do not apply to a target that does not
  claim the profile, since it accepts none.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.{Checks.Discovery, Fixtures}

  @model "model:hcp-conformance"

  def group, do: "conflicts"

  def checks do
    person = [requires: [:rest, :person]]
    agent = [requires: [:rest, :person, :agent]]

    [
      Check.new(
        "conflicts.quarantine",
        "4.7.2",
        :must,
        "An inference a client says contradicts the person's own statement is quarantined, and the statement stays active",
        &quarantine/1,
        agent
      ),
      Check.new(
        "conflicts.symmetric",
        "4.2.3",
        :must,
        "A contradicts relationship is recorded on both entries, with the asserter and the time set by the provider",
        &symmetric/1,
        agent
      ),
      Check.new(
        "conflicts.audited",
        "4.7.2",
        :must,
        "conflict.detected names the quarantined entry as entryId and the authoritative one as relatedEntryId",
        &audited/1,
        agent
      ),
      Check.new(
        "conflicts.withheld",
        "4.7.2",
        :must,
        "A conflicted entry is never returned to a Context Client, by query or by its ref",
        &withheld/1,
        agent
      ),
      Check.new(
        "conflicts.both_unverified",
        "4.7.2",
        :must,
        "Where neither entry is authoritative, both are quarantined for the person to resolve",
        &both_unverified/1,
        agent
      ),
      Check.new(
        "conflicts.own_statements",
        "4.7",
        :must,
        "A conflict between two of the person's own statements changes no status, and is recorded as conflict.detected",
        &own_statements/1,
        person
      ),
      Check.new(
        "conflicts.asserter_corrects",
        "4.7",
        :must,
        "An asserter's later inference deprecates its earlier one, recorded as detected and then resolved",
        &asserter_corrects/1,
        agent
      ),
      Check.new(
        "conflicts.reject",
        "4.7.3",
        :must,
        "Rejecting a conflicted entry deletes it and returns the other quarantined entry to active",
        &reject/1,
        agent
      ),
      Check.new(
        "conflicts.accept",
        "4.7.3",
        :must,
        "Accepting a conflicted entry makes it active without changing its declaration type, and deprecates the entry that was authoritative",
        &accept/1,
        agent
      ),
      Check.new(
        "conflicts.supersede",
        "4.7.3",
        :must,
        "A revision after which the conflict no longer stands returns the quarantined entry to active",
        &supersede/1,
        agent
      ),
      Check.new(
        "conflicts.authoritative_withdrawn",
        "4.7.3",
        :must,
        "Withdrawing the authoritative entry leaves the conflicted entry conflicted",
        &authoritative_withdrawn/1,
        agent
      ),
      Check.new(
        "conflicts.target_unreadable",
        "4.2.3",
        :must,
        "A relationship to an entry the client cannot read fails with 403 scope-denied",
        &target_unreadable/1,
        agent
      ),
      Check.new(
        "conflicts.proposal",
        "4.7.4",
        :must,
        "A proposal changes no status, is recorded as conflict.proposed with the provider naming its author, and is not disclosed to a Context Client",
        &proposal/1,
        agent
      ),
      Check.new(
        "conflicts.proposal_followed",
        "4.7.4",
        :must,
        "When the person performs the act a proposal named, conflict.resolved records that it followed a proposal",
        &proposal_followed/1,
        agent
      ),
      Check.new(
        "conflicts.inferred_names_asserter",
        "5.2.3",
        :must,
        "A model-inferred write that names no asserter is rejected with 422 malformed-request",
        &inferred_names_asserter/1,
        person
      ),
      Check.new(
        "conflicts.dimension_alone",
        "15.2",
        :must,
        "Two entries are not found to conflict on the basis of sharing a dimension alone",
        &dimension_alone/1,
        agent
      ),
      Check.new(
        "conflicts.detected",
        "15.2",
        :must,
        "A contradiction the provider's method finds is recorded as a contradicts relationship asserted by the hcp-provider, and quarantines the inference",
        &detected/1,
        agent
      ),
      Check.new(
        "conflicts.detection_symmetric",
        "15.2",
        :must,
        "Detection is evaluated on every write: the inference is quarantined whichever entry is written second",
        &detection_symmetric/1,
        agent
      ),
      Check.new(
        "conflicts.reevaluated",
        "15.3",
        :must,
        "When a revision means the method no longer finds the conflict, the provider removes its relationship and the inference returns to active",
        &reevaluated/1,
        agent
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)
  defp agent(ctx), do: Context.agent!(ctx).token

  # An inference is accepted only by a provider that claims the profile (§18.1).
  defp inferences!(ctx) do
    if Discovery.memory_manager() not in List.wrap((ctx.discovery || %{})["conformsTo"]) do
      Assert.not_applicable!(
        "the target does not claim the Memory Manager Profile, so it accepts no model-inferred entries"
      )
    end
  end

  # Writing ---------------------------------------------------------------------------

  # A statement with a word of its own, so the suite finds exactly this entry again.
  defp statement(ctx, text), do: "#{text} #{Context.unique_word(ctx)}"

  defp declare!(ctx, text, opts \\ []),
    do: Fixtures.create!(ctx, person(ctx), [value: text] ++ opts)

  # The ref a Context Client knows an entry by: it finds the entry by its statement.
  defp ref!(ctx, text) do
    word = text |> String.split() |> List.last()

    case Enum.find(
           Fixtures.found(ctx, agent(ctx), word),
           &(get_in(&1, ["content", "value"]) == text)
         ) do
      %{"ref" => ref} -> ref
      nil -> Assert.fail!("the Context Client cannot find the entry it is to relate to")
    end
  end

  defp contradicts(ref, extra \\ %{}),
    do: [Map.merge(%{"type" => "contradicts", "target" => ref}, extra)]

  defp infer!(ctx, text, opts \\ []) do
    opts =
      [value: text, declaration_type: "model-inferred", confidence: "medium", asserted_by: @model] ++
        opts

    Fixtures.create!(ctx, agent(ctx), opts)
  end

  # The person's statement and a client's inference that says it contradicts it.
  defp contradicted!(ctx, extra \\ %{}) do
    inferences!(ctx)
    declared = statement(ctx, "I drink tea called")
    inferred = statement(ctx, "Drinks coffee called")
    declaration = declare!(ctx, declared)
    infer!(ctx, inferred, relationships: contradicts(ref!(ctx, declared), extra))
    %{declared: declared, inferred: inferred, declaration: declaration}
  end

  # A statement the client says the person made, and its inference against it:
  # neither has the standing of the person's own statement (§3.7).
  defp unverified_pair!(ctx) do
    inferences!(ctx)
    said = statement(ctx, "I drink tea called")
    inferred = statement(ctx, "Drinks coffee called")
    said_ref = Fixtures.create!(ctx, agent(ctx), value: said)["ref"]
    infer!(ctx, inferred, relationships: contradicts(said_ref))
    %{said: said, inferred: inferred}
  end

  # Reading as the person -----------------------------------------------------------------

  # Every entry as held, whatever its status: the export carries them all (§5.4.1).
  defp held!(ctx, text) do
    response = Context.request(ctx, :get, Context.url(ctx, :export), token: person(ctx))
    Assert.status!(response, 200, "GET /v2/export")
    entries = List.wrap(Assert.json_object!(response, "GET /v2/export")["entries"])

    Enum.find(entries, &(get_in(&1, ["content", "value"]) == text)) ||
      Assert.fail!("the person's export does not hold the entry #{inspect(text)}")
  end

  defp status!(ctx, text, expected, why) do
    entry = held!(ctx, text)
    status = get_in(entry, ["record", "status"])

    Assert.check!(
      status == expected,
      "#{why}: its status is #{inspect(status)}, expected #{expected}"
    )

    entry
  end

  defp relationships(entry, target) do
    for %{"type" => "contradicts", "target" => ^target} = relationship <-
          List.wrap(get_in(entry, ["record", "relationships"])),
        do: relationship
  end

  defp confirm!(ctx, entry, disposition) do
    body = %{
      "disposition" => disposition,
      "expectedVersion" => get_in(entry, ["record", "version"])
    }

    url = Context.entry_url(ctx, entry["id"]) <> "/confirmation"
    response = Context.request(ctx, :post, url, token: person(ctx), json: body)
    Assert.status!(response, 200, "POST /v2/entries/{entryId}/confirmation")
  end

  defp event!(ctx, type, entry_id, extra \\ fn _event -> true end) do
    match =
      &(AuditLog.event?(&1, type) and entry_id in [&1["entryId"], &1["relatedEntryId"]] and
          extra.(&1))

    [event | _] = AuditLog.await!(ctx, "#{type} for the entry", match)
    event
  end

  defp transition?(transition), do: &(get_in(&1, ["data", "transition"]) == transition)

  # Core: what an asserted conflict changes (§4.7) --------------------------------------------

  defp quarantine(ctx) do
    pair = contradicted!(ctx)

    status!(
      ctx,
      pair.inferred,
      "conflicted",
      "the inference a client said contradicts the person's own statement"
    )

    status!(ctx, pair.declared, "active", "the person's own statement, which is authoritative")
  end

  defp symmetric(ctx) do
    inferences!(ctx)
    declared = statement(ctx, "I drink tea called")
    inferred = statement(ctx, "Drinks coffee called")
    declare!(ctx, declared)

    forged = %{
      "assertedBy" => %{"role" => "management-client", "id" => "urn:forged"},
      "recordedAt" => "2001-01-01T00:00:00Z"
    }

    infer!(ctx, inferred, relationships: contradicts(ref!(ctx, declared), forged))

    declaration = held!(ctx, declared)
    inference = held!(ctx, inferred)

    Assert.check!(
      relationships(declaration, inference["id"]) != [],
      "the entry contradicted carries no relationship back to the one that contradicts it"
    )

    case relationships(inference, declaration["id"]) do
      [relationship | _] ->
        Assert.check!(
          get_in(relationship, ["assertedBy", "role"]) == "context-client",
          "assertedBy must name the role of the client that asserted the relationship, not what the request said"
        )

        Assert.check!(
          get_in(relationship, ["assertedBy", "id"]) != "urn:forged",
          "assertedBy was taken from the request"
        )

        Assert.check!(
          Fixtures.date_time?(relationship["recordedAt"]) and
            relationship["recordedAt"] != "2001-01-01T00:00:00Z",
          "recordedAt must be set by the provider"
        )

      [] ->
        Assert.fail!(
          "the inference carries no contradicts relationship naming the entry by its id"
        )
    end
  end

  defp audited(ctx) do
    pair = contradicted!(ctx)
    inference = held!(ctx, pair.inferred)
    event = event!(ctx, "conflict.detected", inference["id"])

    Assert.check!(
      event["entryId"] == inference["id"],
      "entryId must identify the conflicted entry"
    )

    Assert.check!(
      event["relatedEntryId"] == pair.declaration["id"],
      "relatedEntryId must identify the authoritative entry"
    )

    role = get_in(event, ["participants", "initiator", "role"])

    Assert.check!(
      role in ["hcp-provider", "authorization-service"],
      "a conflict has no initiating client; the event names #{inspect(role)}"
    )
  end

  defp withheld(ctx) do
    inferences!(ctx)
    declared = statement(ctx, "I drink tea called")
    inferred = statement(ctx, "Drinks coffee called")
    declare!(ctx, declared)
    ref = infer!(ctx, inferred, relationships: contradicts(ref!(ctx, declared)))["ref"]
    status!(ctx, inferred, "conflicted", "the inference")

    word = inferred |> String.split() |> List.last()

    Assert.check!(
      Fixtures.found(ctx, agent(ctx), word) == [],
      "a query returned a conflicted entry to a Context Client"
    )

    Assert.problem!(
      Fixtures.get(ctx, agent(ctx), ref),
      403,
      "scope-denied",
      "reading a conflicted entry by its ref"
    )
  end

  defp both_unverified(ctx) do
    pair = unverified_pair!(ctx)

    status!(
      ctx,
      pair.inferred,
      "conflicted",
      "the inference, against a statement that is not authoritative"
    )

    status!(
      ctx,
      pair.said,
      "conflicted",
      "the unverified statement: a declaration type a client supplies gives it no standing"
    )
  end

  defp own_statements(ctx) do
    first = statement(ctx, "I drink tea called")
    second = statement(ctx, "I drink coffee called")
    earlier = declare!(ctx, first)
    later = declare!(ctx, second, relationships: contradicts(earlier["id"]))
    status!(ctx, first, "active", "the person's earlier statement")
    status!(ctx, second, "active", "the person's later statement")
    event = event!(ctx, "conflict.detected", later["id"])

    Assert.check!(
      Enum.sort([event["entryId"], event["relatedEntryId"]]) ==
        Enum.sort([earlier["id"], later["id"]]),
      "conflict.detected must identify both entries"
    )
  end

  defp asserter_corrects(ctx) do
    inferences!(ctx)
    earlier = statement(ctx, "Drinks tea called")
    later = statement(ctx, "Drinks coffee called")
    ref = infer!(ctx, earlier)["ref"]
    infer!(ctx, later, relationships: contradicts(ref))

    corrected =
      status!(
        ctx,
        earlier,
        "deprecated",
        "the asserter's earlier inference, which its later one corrects"
      )

    status!(ctx, later, "active", "the asserter's later inference")
    event!(ctx, "conflict.detected", corrected["id"])
    event!(ctx, "conflict.resolved", corrected["id"], transition?("asserter-superseded"))
  end

  # Core: the person's acts (§4.7.3) -----------------------------------------------------------

  defp reject(ctx) do
    pair = unverified_pair!(ctx)
    inference = status!(ctx, pair.inferred, "conflicted", "the inference")
    confirm!(ctx, inference, "rejected")

    rejected = status!(ctx, pair.inferred, "deleted", "the rejected entry")
    records = List.wrap(get_in(rejected, ["record", "provenance", "confirmations"]))

    Assert.check!(
      match?(%{"disposition" => "rejected"}, List.last(records)),
      "the rejected entry must carry a rejected confirmation record"
    )

    other =
      status!(
        ctx,
        pair.said,
        "active",
        "the other quarantined entry, which has no other unresolved conflict"
      )

    Assert.check!(
      List.wrap(get_in(other, ["record", "provenance", "confirmations"])) == [],
      "rejecting one entry must not record a confirmation on the other"
    )

    event!(ctx, "conflict.resolved", inference["id"], transition?("rejected"))
  end

  defp accept(ctx) do
    pair = contradicted!(ctx)
    inference = status!(ctx, pair.inferred, "conflicted", "the inference")
    confirm!(ctx, inference, "confirmed")

    accepted = status!(ctx, pair.inferred, "active", "the accepted entry")

    Assert.check!(
      get_in(accepted, ["assertion", "declarationType"]) == "model-inferred",
      "accepting an inference must not rewrite its declaration type"
    )

    Assert.check!(
      get_in(accepted, ["record", "provenance", "assertedBy", "id"]) == @model,
      "accepting an inference must not change its asserter (invariant 12)"
    )

    status!(ctx, pair.declared, "deprecated", "the entry that was authoritative")
    event!(ctx, "conflict.resolved", inference["id"], transition?("accepted"))
  end

  defp supersede(ctx) do
    pair = contradicted!(ctx)
    inference = status!(ctx, pair.inferred, "conflicted", "the inference")
    # A client's relationship ends with a revision that does not assert it again (§4.2.3).
    body = %{
      "expectedVersion" => 1,
      "content" => %{
        "profile" => Fixtures.general_context(),
        "value" => statement(ctx, "I drink water called")
      }
    }

    Assert.status!(
      Fixtures.revise(ctx, person(ctx), pair.declaration["id"], body),
      201,
      "the person's revision"
    )

    released =
      status!(
        ctx,
        pair.inferred,
        "active",
        "the entry the conflict quarantined, once it no longer stands"
      )

    Assert.check!(
      relationships(released, pair.declaration["id"]) == [],
      "the relationship the revision did not assert again is still recorded"
    )

    event!(ctx, "conflict.resolved", inference["id"])
  end

  defp authoritative_withdrawn(ctx) do
    pair = contradicted!(ctx)

    Assert.status!(
      Fixtures.delete(ctx, person(ctx), pair.declaration["id"]),
      200,
      "withdrawing the authoritative entry"
    )

    status!(
      ctx,
      pair.inferred,
      "conflicted",
      "the conflicted entry, which does not gain standing by the removal of what it contradicted"
    )
  end

  defp target_unreadable(ctx) do
    body = Fixtures.entry_body(ctx, relationships: contradicts("r_" <> Context.random_word(14)))
    response = Fixtures.post(ctx, agent(ctx), body)

    Assert.problem!(
      response,
      403,
      "scope-denied",
      "a relationship to an entry the client cannot read"
    )
  end

  # Proposals (§4.7.4) ---------------------------------------------------------------------

  defp proposed!(ctx) do
    inferences!(ctx)
    declared = statement(ctx, "I drink tea called")
    inferred = statement(ctx, "Drinks coffee called")
    declaration = declare!(ctx, declared)
    ref = ref!(ctx, declared)
    rationale = "Recent orders say otherwise " <> Context.unique_word(ctx)

    proposal = %{
      "act" => "reject",
      "entry" => ref,
      "rationale" => rationale,
      "weighed" => ["recency"],
      "proposedBy" => %{"role" => "management-client", "id" => "urn:forged"},
      "proposedAt" => "2001-01-01T00:00:00Z"
    }

    infer!(ctx, inferred, relationships: contradicts(ref, %{"proposal" => proposal}))
    %{declared: declared, inferred: inferred, declaration: declaration, rationale: rationale}
  end

  defp proposal(ctx) do
    pair = proposed!(ctx)

    declaration =
      status!(
        ctx,
        pair.declared,
        "active",
        "the entry a proposal would have rejected; a provider never applies a proposal"
      )

    event = event!(ctx, "conflict.proposed", declaration["id"])

    Assert.check!(
      get_in(event, ["data", "act"]) == "reject",
      "conflict.proposed must record the act proposed"
    )

    recorded =
      for %{"proposal" => %{} = proposal} <-
            List.wrap(get_in(held!(ctx, pair.inferred), ["record", "relationships"])),
          do: proposal

    Assert.check!(
      recorded != [],
      "the proposal is not surfaced with the conflict, on the relationship that records it"
    )

    [proposal | _] = recorded

    Assert.check!(
      get_in(proposal, ["proposedBy", "id"]) != "urn:forged" and
        proposal["proposedAt"] != "2001-01-01T00:00:00Z",
      "proposedBy and proposedAt were taken from the request"
    )

    word = pair.declared |> String.split() |> List.last()
    disclosed = Fixtures.query!(ctx, agent(ctx), %{"query" => word})

    Assert.check!(
      not String.contains?(Jason.encode!(disclosed), pair.rationale),
      "a proposal was disclosed to a Context Client"
    )
  end

  defp proposal_followed(ctx) do
    pair = proposed!(ctx)
    confirm!(ctx, pair.declaration, "rejected")
    event = event!(ctx, "conflict.resolved", pair.declaration["id"], transition?("rejected"))

    Assert.check!(
      get_in(event, ["data", "proposal"]) == true,
      "conflict.resolved must record that the act followed a proposal"
    )
  end

  # The Memory Manager Profile (§15) --------------------------------------------------------

  defp inferred_names_asserter(ctx) do
    inferences!(ctx)
    body = Fixtures.entry_body(ctx, declaration_type: "model-inferred", confidence: "medium")
    response = Fixtures.post(ctx, person(ctx), body)

    Assert.problem!(
      response,
      422,
      "malformed-request",
      "a model-inferred write naming no asserter"
    )
  end

  defp dimension_alone(ctx) do
    inferences!(ctx)
    dimension = "pastime_" <> Context.random_word(8)
    declared = statement(ctx, "I enjoy hiking in")
    inferred = statement(ctx, "Enjoys swimming at")
    declaration = declare!(ctx, declared, dimension: dimension)
    infer!(ctx, inferred, dimension: dimension)

    inference =
      status!(
        ctx,
        inferred,
        "active",
        "an inference that shares a dimension with a statement it does not contradict"
      )

    Assert.check!(
      relationships(inference, declaration["id"]) == [],
      "a contradicts relationship was recorded between two entries that share only a dimension"
    )
  end

  # The plainest contradiction: a statement and its negation, on one dimension.
  # `order` says which is written second.
  defp negated!(ctx, order) do
    inferences!(ctx)
    word = Context.unique_word(ctx)
    dimension = "diet_" <> Context.random_word(8)
    pair = %{declared: "I am #{word}.", inferred: "I am not #{word}.", word: word}

    writes = [
      fn -> declare!(ctx, pair.declared, dimension: dimension) end,
      fn -> infer!(ctx, pair.inferred, dimension: dimension) end
    ]

    Enum.each(if(order == :inference_second, do: writes, else: Enum.reverse(writes)), & &1.())
    pair
  end

  defp found?(ctx, pair),
    do: get_in(held!(ctx, pair.inferred), ["record", "status"]) == "conflicted"

  defp found!(ctx, pair) do
    if not found?(ctx, pair) do
      method = (ctx.discovery || %{})["conflict_detection"]

      Assert.not_applicable!(
        "the provider's method (#{inspect(method)}) did not find the suite's contradiction, a statement and its negation; what follows from a detection cannot be observed"
      )
    end
  end

  defp detected(ctx) do
    pair = negated!(ctx, :inference_second)
    found!(ctx, pair)
    declaration = status!(ctx, pair.declared, "active", "the person's own statement")
    inference = held!(ctx, pair.inferred)

    for {entry, other} <- [{inference, declaration}, {declaration, inference}] do
      roles =
        for relationship <- relationships(entry, other["id"]),
            do: get_in(relationship, ["assertedBy", "role"])

      Assert.check!(
        "hcp-provider" in roles,
        "each entry must carry the contradicts relationship, asserted by the hcp-provider; found #{inspect(roles)}"
      )
    end

    event = event!(ctx, "conflict.detected", inference["id"])

    Assert.check!(
      event["entryId"] == inference["id"] and event["relatedEntryId"] == declaration["id"],
      "conflict.detected must name the inference as entryId and the statement as relatedEntryId"
    )
  end

  defp detection_symmetric(ctx) do
    found!(ctx, negated!(ctx, :inference_second))
    reversed = negated!(ctx, :declaration_second)

    status!(
      ctx,
      reversed.inferred,
      "conflicted",
      "the inference, written before the statement it contradicts"
    )

    status!(ctx, reversed.declared, "active", "the person's own statement, written second")
  end

  defp reevaluated(ctx) do
    pair = negated!(ctx, :inference_second)
    found!(ctx, pair)
    declaration = held!(ctx, pair.declared)
    inference = held!(ctx, pair.inferred)
    # The person changes their statement to say what the inference says.
    body = %{
      "expectedVersion" => 1,
      "content" => %{"profile" => Fixtures.general_context(), "value" => pair.inferred <> " "}
    }

    Assert.status!(
      Fixtures.revise(ctx, person(ctx), declaration["id"], body),
      201,
      "the person's revision"
    )

    released = Enum.find(exported(ctx), &(&1["id"] == inference["id"]))

    Assert.check!(
      get_in(released, ["record", "status"]) == "active",
      "the inference must return to active once the method no longer finds the conflict"
    )

    Assert.check!(
      relationships(released, declaration["id"]) == [],
      "the provider must remove the relationship it asserted"
    )

    event!(ctx, "conflict.resolved", inference["id"])
  end

  defp exported(ctx) do
    response = Context.request(ctx, :get, Context.url(ctx, :export), token: person(ctx))
    List.wrap(Assert.json_object!(response, "GET /v2/export")["entries"])
  end
end
