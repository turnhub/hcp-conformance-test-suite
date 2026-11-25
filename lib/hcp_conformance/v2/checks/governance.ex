defmodule HcpConformance.V2.Checks.Governance do
  @moduledoc """
  The governance plane (§1.6, §5.4, §6.1.9): every governance operation is the
  Management Client's alone and fails with not authorized for a Context Client,
  whatever its grant. And the governance operations on one entry: confirming or
  rejecting it (§3.8), changing its categories (§4.2.1) and restricting its
  purposes (§4.2.6), each naming the version the person saw.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.{Fixtures, Target}

  # {id suffix, what it is, method, how to build the URL and body}
  @operations [
    {"audit", "read the audit log", :get, :audit, nil},
    {"export", "export", :get, :export, nil},
    {"list_rules", "list standing rules", :get, :rules, nil},
    {"set_rule", "set a standing rule", :post, :rules,
     %{"operators" => ["denied.conformance.hcp.example"]}},
    {"list_directives", "list directives", :get, :directives, nil},
    {"set_directive", "set a directive", :post, :directives,
     %{"action" => "share", "effect" => "deny", "text" => "HCP conformance check"}},
    {"confirm", "confirm an entry", :post, {:entry, "/confirmation"},
     %{"disposition" => "confirmed", "expectedVersion" => 1}},
    {"recategorize", "change an entry's categories", :put, {:entry, "/categories"}, :categories},
    {"restrict", "restrict an entry's purposes", :put, {:entry, "/purposes"},
     %{
       "permittedPurposes" => ["https://conformance.hcp.example/purposes/other"],
       "expectedVersion" => 1
     }}
  ]

  def group, do: "governance"

  def checks do
    person = [requires: [:rest, :person]]
    agent = [requires: [:rest, :person, :agent]]

    refusals =
      for {suffix, what, method, target, body} <- @operations do
        Check.new(
          "governance.refused.#{suffix}",
          "6.1.9",
          :must,
          "A Context Client cannot #{what}: the attempt fails with 403 scope-denied",
          &refused(&1, what, method, target, body),
          requires: [:rest, :agent]
        )
      end

    refusals ++
      [
        Check.new(
          "governance.confirm",
          "3.8",
          :must,
          "Confirming appends a confirmation record without a new version or a changed declaration type, audited as context.confirmed",
          &confirm/1,
          person
        ),
        Check.new(
          "governance.confirm_version_conflict",
          "5.4",
          :must,
          "A confirmation naming a stale expectedVersion fails with 409 version-conflict and changes nothing",
          &confirm_version_conflict/1,
          person
        ),
        Check.new(
          "governance.reject",
          "4.7.3",
          :must,
          "Rejecting an entry appends a rejected record and sets its status to deleted",
          &reject/1,
          person
        ),
        Check.new(
          "governance.confirmed_standing",
          "7.4",
          :must,
          "A disclosure of a confirmed entry reports standing.confirmed as true",
          &confirmed_standing/1,
          agent
        ),
        Check.new(
          "governance.recategorize",
          "4.2.1",
          :must,
          "Changing categories keeps the version and appends context.recategorized naming the prior and new categories",
          &recategorize/1,
          requires: [:rest, :person, :second_category]
        ),
        Check.new(
          "governance.recategorize_moves_scope",
          "4.5",
          :must,
          "An entry moved out of a grant's categories is no longer disclosed under that grant",
          &recategorize_moves_scope/1,
          requires: [:rest, :person, :agent, :second_category]
        ),
        Check.new(
          "governance.restrict_purposes",
          "4.2.6",
          :must,
          "An entry restricted to other purposes is withheld from a request naming this one, audited as context.restricted, until the restriction is lifted",
          &restrict_purposes/1,
          agent
        )
      ]
  end

  defp person(ctx), do: Context.person!(ctx)
  defp agent(ctx), do: Context.agent!(ctx).token

  defp refused(ctx, what, method, target, body) do
    {url, body} = operation(ctx, target, body)
    opts = [token: agent(ctx)] ++ if(body, do: [json: body], else: [])
    response = Context.request(ctx, method, url, opts)
    Assert.problem!(response, 403, "scope-denied", "a Context Client trying to #{what}")
  end

  # An entry operation is tried on an entry the client itself wrote, by its ref:
  # the one entry it can name, so only the plane stands in its way.
  defp operation(ctx, {:entry, suffix}, body) do
    ref = Fixtures.create!(ctx, agent(ctx))["ref"]

    body =
      if body == :categories,
        do: %{"categories" => [ctx.primary_category], "expectedVersion" => 1},
        else: body

    {Context.entry_url(ctx, ref) <> suffix, body}
  end

  defp operation(ctx, endpoint, body), do: {Context.url(ctx, endpoint), body}

  defp act(ctx, method, id, suffix, body),
    do:
      Context.request(ctx, method, Context.entry_url(ctx, id) <> suffix,
        token: person(ctx),
        json: body
      )

  defp act!(ctx, method, id, suffix, body) do
    response = act(ctx, method, id, suffix, body)

    Assert.status!(
      response,
      200,
      "#{String.upcase(to_string(method))} /v2/entries/{entryId}#{suffix}"
    )

    Assert.json_object!(response, "/v2/entries/{entryId}#{suffix}")
  end

  defp confirmations(entry),
    do: List.wrap(get_in(entry, ["record", "provenance", "confirmations"]))

  defp confirm(ctx) do
    created = Fixtures.create!(ctx, person(ctx))

    entry =
      act!(ctx, :post, created["id"], "/confirmation", %{
        "disposition" => "confirmed",
        "expectedVersion" => 1
      })

    Assert.check!(
      match?([%{"disposition" => "confirmed"}], confirmations(entry)),
      "the entry must carry one confirmed record"
    )

    Assert.check!(
      Fixtures.date_time?(hd(confirmations(entry))["confirmedAt"]),
      "the record must carry confirmedAt"
    )

    Assert.check!(
      get_in(entry, ["record", "version"]) == 1,
      "a confirmation must not create a version"
    )

    Assert.check!(
      entry["assertion"] == created["assertion"],
      "a confirmation must not change the assertion (invariant 12)"
    )

    match =
      &(AuditLog.event?(&1, "context.confirmed", entryId: created["id"]) and
          get_in(&1, ["data", "disposition"]) == "confirmed")

    AuditLog.await!(ctx, "context.confirmed with the disposition", match)
  end

  defp confirm_version_conflict(ctx) do
    created = Fixtures.create!(ctx, person(ctx))

    Assert.status!(
      Fixtures.revise(ctx, person(ctx), created["id"], %{"expectedVersion" => 1}),
      201,
      "the revision"
    )

    response =
      act(ctx, :post, created["id"], "/confirmation", %{
        "disposition" => "confirmed",
        "expectedVersion" => 1
      })

    Assert.problem!(
      response,
      409,
      "version-conflict",
      "a confirmation of a version the person has not seen"
    )

    Assert.check!(
      confirmations(Fixtures.get!(ctx, person(ctx), created["id"])) == [],
      "the refused confirmation was recorded"
    )
  end

  defp reject(ctx) do
    created = Fixtures.create!(ctx, person(ctx))

    entry =
      act!(ctx, :post, created["id"], "/confirmation", %{
        "disposition" => "rejected",
        "expectedVersion" => 1
      })

    Assert.check!(
      match?([%{"disposition" => "rejected"}], confirmations(entry)),
      "the entry must carry one rejected record"
    )

    Assert.check!(
      get_in(entry, ["record", "status"]) == "deleted",
      "a rejected entry's status must be deleted"
    )
  end

  defp confirmed_standing(ctx) do
    word = Context.unique_word(ctx)
    created = Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)
    [before] = Fixtures.found(ctx, agent(ctx), word)

    Assert.check!(
      get_in(before, ["standing", "confirmed"]) == false,
      "an unconfirmed entry must report standing.confirmed false"
    )

    act!(ctx, :post, created["id"], "/confirmation", %{
      "disposition" => "confirmed",
      "expectedVersion" => 1
    })

    [later] = Fixtures.found(ctx, agent(ctx), word)

    Assert.check!(
      get_in(later, ["standing", "confirmed"]) == true,
      "a confirmed entry must report standing.confirmed true"
    )
  end

  defp recategorize(ctx) do
    created = Fixtures.create!(ctx, person(ctx))
    to = [ctx.second_category]

    entry =
      act!(ctx, :put, created["id"], "/categories", %{"categories" => to, "expectedVersion" => 1})

    Assert.check!(
      get_in(entry, ["classification", "categories"]) == to,
      "the entry does not carry its new categories"
    )

    Assert.check!(
      get_in(entry, ["record", "version"]) == 1,
      "a change of categories must not create a version"
    )

    match = fn event ->
      AuditLog.event?(event, "context.recategorized", entryId: created["id"]) and
        get_in(event, ["data", "from"]) == [ctx.primary_category] and
        get_in(event, ["data", "to"]) == to
    end

    AuditLog.await!(ctx, "context.recategorized naming the prior and new categories", match)
  end

  defp recategorize_moves_scope(ctx) do
    word = Context.unique_word(ctx)
    created = Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)
    [disclosure] = Fixtures.found(ctx, agent(ctx), word)

    act!(ctx, :put, created["id"], "/categories", %{
      "categories" => [ctx.second_category],
      "expectedVersion" => 1
    })

    Assert.check!(
      Fixtures.found(ctx, agent(ctx), word) == [],
      "a query still returned the entry after it left the grant's category"
    )

    Assert.problem!(
      Fixtures.get(ctx, agent(ctx), disclosure["ref"]),
      403,
      "scope-denied",
      "reading the moved entry by its ref"
    )
  end

  defp restrict_purposes(ctx) do
    word = Context.unique_word(ctx)
    created = Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)
    other = [Target.other_purpose()]

    entry =
      act!(ctx, :put, created["id"], "/purposes", %{
        "permittedPurposes" => other,
        "expectedVersion" => 1
      })

    Assert.check!(
      get_in(entry, ["classification", "permittedPurposes"]) == other,
      "the entry does not carry classification.permittedPurposes"
    )

    Assert.check!(
      Fixtures.found(ctx, agent(ctx), word) == [],
      "the entry was disclosed for a purpose its permitted purposes exclude"
    )

    match =
      &(AuditLog.event?(&1, "context.restricted", entryId: created["id"]) and
          get_in(&1, ["data", "to"]) == other)

    AuditLog.await!(ctx, "context.restricted naming the new list", match)

    act!(ctx, :put, created["id"], "/purposes", %{
      "permittedPurposes" => nil,
      "expectedVersion" => 1
    })

    Assert.check!(
      length(Fixtures.found(ctx, agent(ctx), word)) == 1,
      "lifting the restriction with null did not make the entry readable again"
    )
  end
end
