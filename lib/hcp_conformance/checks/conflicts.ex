defmodule HcpConformance.Checks.Conflicts do
  @moduledoc """
  Conflict detection and resolution (§2.6). A model-inferred entry that shares
  category and dimension with an active user-declared entry must be quarantined,
  whichever was written second; it is then withheld from agents but visible to the
  person, until the person rejects it, accepts it, or deletes what it contradicted.

  The inferred side is written by the agent, since writing model-inferred
  entries is what agents do.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, Envelope, Fixtures}
  alias HcpConformance.Checks.Entries

  def group, do: "conflicts"

  def checks do
    opts = [requires: [:rest, :person, :agent]]

    [
      Check.new(
        "conflicts.inferred_second",
        "2.6.1",
        :must,
        "An inference written after a contradicting declaration is quarantined",
        &inferred_second/1,
        opts
      ),
      Check.new(
        "conflicts.declared_second",
        "2.6.1",
        :must,
        "An inference is quarantined when the contradicting declaration is written after it",
        &declared_second/1,
        opts
      ),
      Check.new(
        "conflicts.dimension_normalized",
        "2.6.1",
        :should,
        "Dimensions are compared after normalization (\"Footwear Support\" matches \"footwear_support\")",
        &dimension_normalized/1,
        opts
      ),
      Check.new(
        "conflicts.audited",
        "2.6.2",
        :must,
        "conflict.detected names the inference as entryId and the declaration as relatedEntryId",
        &audited/1,
        opts
      ),
      Check.new(
        "conflicts.withheld_from_agent",
        "2.6.2",
        :must,
        "A conflicted entry is never returned to an agent, by search or single-entry read, at any version",
        &withheld/1,
        opts
      ),
      Check.new(
        "conflicts.visible_to_person",
        "2.6.2",
        :must,
        "A conflicted entry remains visible to the person",
        &visible/1,
        opts
      ),
      Check.new(
        "conflicts.reject",
        "2.6.3",
        :must,
        "Deleting the inference resolves the conflict, audited, and leaves the declaration active",
        &reject/1,
        opts
      ),
      Check.new(
        "conflicts.accept",
        "2.6.3",
        :must,
        "Updating the inference accepts it: active, user-declared, the old declaration deprecated, audited",
        &accept/1,
        opts
      ),
      Check.new(
        "conflicts.authoritative_deleted",
        "2.6.3",
        :must,
        "Deleting the declaration does not reactivate the inference",
        &authoritative_deleted/1,
        opts
      )
    ]
  end

  # Writes a contradicting pair and returns {declared, inferred}. `order` says
  # which is written second.
  defp pair!(ctx, order, opts \\ []) do
    word = Context.unique_word(ctx)
    dimension = Keyword.get(opts, :dimension, "conformance_" <> word)
    inferred_dimension = Keyword.get(opts, :inferred_dimension, dimension)

    declare = fn ->
      Fixtures.create!(ctx, Context.person!(ctx),
        dimension: dimension,
        preference: "I prefer window seats #{word}"
      )
    end

    infer = fn ->
      Fixtures.create!(ctx, Context.agent!(ctx).token,
        dimension: inferred_dimension,
        declaration_type: "model-inferred",
        confidence: "medium",
        preference: "Prefers aisle seats #{word}",
        user_verified: false
      )
    end

    case order do
      :inferred_second ->
        declared = declare.()
        {declared, infer.(), word}

      :declared_second ->
        inferred = infer.()
        {declare.(), inferred, word}
    end
  end

  defp read!(ctx, id) do
    response = Fixtures.get(ctx, Context.person!(ctx), id)
    Assert.status!(response, 200, "the person reading #{id}")
    Assert.json_object!(response, "GET entry")["entry"] || %{}
  end

  defp status_of(ctx, id),
    do: Envelope.get(read!(ctx, id), ctx.envelope_form, ["record", "status"])

  defp assert_quarantined(ctx, declared, inferred) do
    Assert.check!(
      status_of(ctx, inferred["id"]) == "conflicted",
      "the inference was not quarantined (status #{inspect(status_of(ctx, inferred["id"]))})"
    )

    Assert.check!(
      status_of(ctx, declared["id"]) == "active",
      "the user-declared entry must stay active and authoritative"
    )
  end

  defp inferred_second(ctx) do
    {declared, inferred, _word} = pair!(ctx, :inferred_second)
    assert_quarantined(ctx, declared, inferred)
  end

  defp declared_second(ctx) do
    {declared, inferred, _word} = pair!(ctx, :declared_second)
    assert_quarantined(ctx, declared, inferred)
  end

  defp dimension_normalized(ctx) do
    word = Context.unique_word(ctx)

    {declared, inferred, _word} =
      pair!(ctx, :inferred_second,
        dimension: "  Footwear Support #{word} ",
        inferred_dimension: "footwear_support_#{word}"
      )

    assert_quarantined(ctx, declared, inferred)
  end

  defp audited(ctx) do
    {declared, inferred, _word} = pair!(ctx, :inferred_second)

    AuditLog.await!(
      ctx,
      "conflict.detected",
      &AuditLog.event?(&1, "conflict.detected",
        entryId: inferred["id"],
        relatedEntryId: declared["id"]
      )
    )
  end

  # The inference gets a second version before the conflict arises, so the
  # quarantine must also cover reading an earlier version (§2.6.2 names any
  # single-entry request, and ?version=n is one).
  defp withheld(ctx) do
    agent = Context.agent!(ctx)
    word = Context.unique_word(ctx)
    dimension = "conformance_" <> word

    inferred =
      Fixtures.create!(ctx, agent.token,
        dimension: dimension,
        declaration_type: "model-inferred",
        confidence: "medium",
        preference: "Prefers aisle seats #{word}",
        user_verified: false
      )

    Entries.update!(ctx, agent.token, inferred["id"], "Prefers aisle seats, revised #{word}")

    declared =
      Fixtures.create!(ctx, Context.person!(ctx),
        dimension: dimension,
        preference: "I prefer window seats #{word}"
      )

    assert_quarantined(ctx, declared, inferred)

    body = Fixtures.search!(ctx, agent.token, %{"query" => word, "maxEntries" => 10})

    Assert.check!(
      inferred["id"] not in Fixtures.ids(body),
      "the agent's search returned the conflicted entry"
    )

    Fixtures.get(ctx, agent.token, inferred["id"])
    |> Assert.problem!(403, "scope-denied", "an agent reading a conflicted entry")

    Fixtures.get(ctx, agent.token, inferred["id"], version: 1)
    |> Assert.problem!(403, "scope-denied", "an agent reading version 1 of a conflicted entry")
  end

  defp visible(ctx) do
    {_declared, inferred, _word} = pair!(ctx, :inferred_second)
    entry = read!(ctx, inferred["id"])

    Assert.check!(
      Envelope.get(entry, ctx.envelope_form, ["record", "status"]) == "conflicted",
      "the person must see the entry as conflicted"
    )
  end

  defp reject(ctx) do
    {declared, inferred, _word} = pair!(ctx, :inferred_second)
    Entries.delete!(ctx, Context.person!(ctx), inferred["id"])

    Assert.check!(
      status_of(ctx, declared["id"]) == "active",
      "rejecting the inference changed the declaration"
    )

    AuditLog.await!(
      ctx,
      "conflict.resolved",
      &AuditLog.event?(&1, "conflict.resolved", entryId: inferred["id"])
    )
  end

  defp accept(ctx) do
    {declared, inferred, word} = pair!(ctx, :inferred_second)

    updated =
      Entries.update!(ctx, Context.person!(ctx), inferred["id"], "I prefer aisle seats #{word}")

    field = &Envelope.get(updated, ctx.envelope_form, &1)

    Assert.check!(
      field.(["record", "status"]) == "active",
      "an accepted inference must become active"
    )

    Assert.check!(
      field.(["record", "declarationType"]) == "user-declared",
      "an accepted inference must become user-declared"
    )

    Assert.check!(
      is_nil(field.(["record", "confidence"])),
      "confidence must be null once the entry is user-declared"
    )

    Assert.check!(
      status_of(ctx, declared["id"]) == "deprecated",
      "the previously authoritative entry must be deprecated"
    )

    AuditLog.await!(
      ctx,
      "conflict.resolved",
      &AuditLog.event?(&1, "conflict.resolved", entryId: inferred["id"])
    )
  end

  defp authoritative_deleted(ctx) do
    {declared, inferred, _word} = pair!(ctx, :inferred_second)
    Entries.delete!(ctx, Context.person!(ctx), declared["id"])

    Assert.check!(
      status_of(ctx, inferred["id"]) == "conflicted",
      "deleting the declaration reactivated the inference"
    )
  end
end
