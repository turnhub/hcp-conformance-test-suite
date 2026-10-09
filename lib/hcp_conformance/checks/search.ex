defmodule HcpConformance.Checks.Search do
  @moduledoc """
  searchPreferences over REST (§3.3.1) and the minimization contract it enforces
  (§4.4): category bound, quantity bound without padding, relevance ordering,
  field redaction for agents, and a minimization report that discloses no counts.
  Also the minimal response mode added in draft 4 (§3.1.1).
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, Envelope, Fixtures}
  alias HcpConformance.Checks.Discovery

  @count_keys ~w(count total totalCount total_count available considered withheld matched)

  def group, do: "search"

  def checks do
    person = [requires: [:rest, :person]]
    agent = [requires: [:rest, :person, :agent]]

    [
      Check.new(
        "search.response",
        "3.3.1",
        :must,
        "A search answers 200 with entries, retrievalId, minimization, categoriesSearched and timestamp",
        &response/1,
        person
      ),
      Check.new(
        "search.requires_purpose",
        "3.3.1",
        :must,
        "A search without a purpose is rejected with 422 malformed-request",
        &requires_purpose/1,
        person
      ),
      Check.new(
        "search.method_declared",
        "4.4.3",
        :must,
        "minimization.method matches the method declared in the discovery document",
        &method_declared/1,
        person
      ),
      Check.new(
        "search.default_max",
        "3.3.1",
        :must,
        "Without maxEntries a search returns at most 5 entries",
        &default_max/1,
        person
      ),
      Check.new(
        "search.ceiling",
        "4.4.2",
        :must,
        "A search never returns more than 20 entries, whatever maxEntries asks for",
        &ceiling/1,
        person
      ),
      Check.new(
        "search.not_padded",
        "4.4.2",
        :must,
        "A search does not pad its results to reach maxEntries",
        &not_padded/1,
        person
      ),
      Check.new(
        "search.relevance_order",
        "4.4.3",
        :must,
        "Lexical ordering ranks the entry sharing more query terms first",
        &relevance_order/1,
        person
      ),
      Check.new(
        "search.no_counts",
        "4.4.5",
        :must,
        "The response discloses no count of entries considered, available or withheld",
        &no_counts/1,
        person
      ),
      Check.new(
        "search.not_paginated",
        "3.4.2",
        :must,
        "Search responses are not paginated",
        &not_paginated/1,
        person
      ),
      Check.new(
        "search.audited",
        "4.3.1",
        :must,
        "A search appends preference.read with the stated purpose",
        &audited/1,
        person
      ),
      Check.new(
        "search.person_unredacted",
        "4.4.5",
        :must,
        "The person's own search is not redacted and reports redactedFields as []",
        &person_unredacted/1,
        person
      ),
      Check.new(
        "search.agent_redaction",
        "4.4.4",
        :must,
        "An agent's results omit record.provenance.source and capturedBy, and redactedFields names them",
        &agent_redaction/1,
        agent
      ),
      Check.new(
        "search.category_bound",
        "4.4.1",
        :must,
        "An agent searching a category outside its grant is refused with 403 scope-denied",
        &category_bound/1,
        agent
      ),
      Check.new(
        "search.category_isolation",
        "4.4.1",
        :must,
        "An agent's results never include entries from categories its grant does not cover",
        &category_isolation/1,
        requires: [:rest, :person, :agent, :second_category]
      ),
      Check.new(
        "search.minimal_response",
        "3.1.1",
        :must,
        "responseDetail \"minimal\" reduces Tier 1 entries to id, category, dimension and value",
        &minimal_response/1,
        person
      )
    ]
  end

  defp seed!(ctx, count, word) do
    for index <- 1..count do
      Fixtures.create!(ctx, Context.person!(ctx), preference: "Seeded statement #{index} #{word}")
    end
  end

  defp response(ctx) do
    word = Context.unique_word(ctx)
    [entry] = seed!(ctx, 1, word)
    body = Fixtures.search!(ctx, Context.person!(ctx), %{"query" => word})

    Assert.check!(is_list(body["entries"]), "the body must carry an entries array")
    Assert.check!(entry["id"] in Fixtures.ids(body), "the search did not return the entry it matches")
    Assert.check!(is_binary(body["retrievalId"]), "the body must carry a retrievalId")
    Assert.check!(is_map(body["minimization"]), "the body must carry a minimization object")
    Assert.check!(is_list(body["categoriesSearched"]), "the body must carry categoriesSearched")
    Assert.check!(Envelope.iso8601?(body["timestamp"]), "the body must carry an ISO-8601 timestamp")
  end

  defp requires_purpose(ctx) do
    response =
      Context.request(ctx, :post, Context.url(ctx, :search),
        token: Context.person!(ctx),
        json: %{"query" => "conformance", "categories" => [ctx.primary_category]}
      )

    Assert.problem!(response, 422, "malformed-request", "search without purpose")
  end

  defp method_declared(ctx) do
    declared = Discovery.discovery!(ctx)["minimization_method"]
    body = Fixtures.search!(ctx, Context.person!(ctx), %{"query" => Context.unique_word(ctx)})
    method = get_in(body, ["minimization", "method"])

    Assert.check!(
      method == declared,
      "discovery declares #{inspect(declared)}, the search reports #{inspect(method)}"
    )
  end

  defp default_max(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, 7, word)
    body = Fixtures.search!(ctx, Context.person!(ctx), %{"query" => word})
    count = length(body["entries"] || [])
    Assert.check!(count in 1..5, "expected between 1 and 5 entries with the default maxEntries, got #{count}")
  end

  defp ceiling(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, 22, word)

    response =
      Context.request(ctx, :post, Context.url(ctx, :search),
        token: Context.person!(ctx),
        json: %{
          "query" => word,
          "categories" => [ctx.primary_category],
          "purpose" => "HCP conformance check",
          "maxEntries" => 50
        }
      )

    case response.status do
      # A schema that caps maxEntries at 20 (the MCP schema does) may refuse 50 outright.
      422 ->
        :ok

      200 ->
        count = length(Assert.json_object!(response, "search")["entries"] || [])

        Assert.check!(
          count in 1..20,
          "maxEntries 50 over 22 matching entries returned #{count} entries; the ceiling is 20"
        )

      _other ->
        Assert.status!(response, [200, 422], "search with maxEntries 50")
    end
  end

  # Other entries exist in the category, so padding has something to pad with.
  defp not_padded(ctx) do
    seed!(ctx, 3, Context.unique_word(ctx))
    word = Context.unique_word(ctx)
    seeded = seed!(ctx, 2, word) |> Enum.map(& &1["id"])
    body = Fixtures.search!(ctx, Context.person!(ctx), %{"query" => word, "maxEntries" => 10})
    returned = Fixtures.ids(body)
    extra = returned -- seeded

    Assert.check!(
      extra == [],
      "two entries match, maxEntries was 10, and the search added #{length(extra)} unrelated entries"
    )
  end

  defp relevance_order(ctx) do
    if Discovery.discovery!(ctx)["minimization_method"] != "lexical",
      do: Assert.not_applicable!("the declared method is not lexical, so the expected order cannot be stated")

    word = Context.unique_word(ctx)
    second_word = Context.unique_word(ctx)
    strong = Fixtures.create!(ctx, Context.person!(ctx), preference: "Strong match #{word} #{second_word}")
    weak = Fixtures.create!(ctx, Context.person!(ctx), preference: "Weak match #{word}")

    body =
      Fixtures.search!(ctx, Context.person!(ctx), %{"query" => "#{word} #{second_word}", "maxEntries" => 10})

    ids = Fixtures.ids(body)
    strong_at = Enum.find_index(ids, &(&1 == strong["id"]))
    weak_at = Enum.find_index(ids, &(&1 == weak["id"]))

    Assert.check!(strong_at != nil, "the entry sharing both query terms was not returned")

    Assert.check!(
      is_nil(weak_at) or strong_at < weak_at,
      "the entry sharing one term (and newer) ranked above the entry sharing both"
    )
  end

  defp no_counts(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, 3, word)
    body = Fixtures.search!(ctx, Context.person!(ctx), %{"query" => word, "maxEntries" => 1})
    minimization = body["minimization"] || %{}
    extra = Map.keys(minimization) -- ["method", "redactedFields"]

    Assert.check!(
      extra == [],
      "minimization carries members beyond method and redactedFields: #{inspect(extra)}"
    )

    leaked = Enum.filter(@count_keys, &(Map.has_key?(body, &1) or Map.has_key?(minimization, &1)))
    Assert.check!(leaked == [], "the response discloses counts: #{inspect(leaked)}")
  end

  defp not_paginated(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, 3, word)
    body = Fixtures.search!(ctx, Context.person!(ctx), %{"query" => word, "maxEntries" => 1})
    present = Enum.filter(["nextCursor", "cursor", "next", "nextPage"], &Map.has_key?(body, &1))
    Assert.check!(present == [], "a search response must not offer pagination, found #{inspect(present)}")
  end

  defp audited(ctx) do
    purpose = "Conformance search " <> Context.unique_word(ctx)
    Fixtures.search!(ctx, Context.person!(ctx), %{"query" => Context.unique_word(ctx), "purpose" => purpose})

    AuditLog.await!(ctx, "preference.read", &AuditLog.event?(&1, "preference.read", purpose: purpose),
      read?: true
    )
  end

  defp person_unredacted(ctx) do
    word = Context.unique_word(ctx)
    [entry] = seed!(ctx, 1, word)
    body = Fixtures.search!(ctx, Context.person!(ctx), %{"query" => word})

    Assert.check!(
      get_in(body, ["minimization", "redactedFields"]) == [],
      "redactedFields must be [] for the person"
    )

    found = Enum.find(body["entries"] || [], &(&1["id"] == entry["id"]))
    Assert.check!(found != nil, "the search did not return the entry it matches")
    source = Envelope.get(found, ctx.envelope_form, ["record", "provenance", "source"])
    Assert.check!(is_binary(source), "record.provenance.source was redacted from the person's own search")
  end

  defp agent_redaction(ctx) do
    word = Context.unique_word(ctx)
    [entry] = seed!(ctx, 1, word)
    body = Fixtures.search!(ctx, Context.agent!(ctx).token, %{"query" => word})
    found = Enum.find(body["entries"] || [], &(&1["id"] == entry["id"]))
    Assert.check!(found != nil, "the agent's search did not return the entry it matches")
    provenance = Envelope.get(found, ctx.envelope_form, ["record", "provenance"]) || %{}

    leaked = Enum.filter(["source", "capturedBy"], &Map.has_key?(provenance, &1))
    Assert.check!(leaked == [], "provenance fields returned to an agent: #{inspect(leaked)}")

    expected =
      Enum.map(
        [["record", "provenance", "source"], ["record", "provenance", "capturedBy"]],
        &Envelope.path(ctx.envelope_form, &1)
      )

    reported = get_in(body, ["minimization", "redactedFields"]) || []
    missing = expected -- reported

    Assert.check!(
      missing == [],
      "redactedFields must name #{inspect(expected)} (paths in the returned form), got #{inspect(reported)}"
    )

    violations = Envelope.validate(found, ctx.envelope_form, redacted: true)

    Assert.check!(
      violations == [],
      "the entry returned to the agent is invalid: " <> Enum.join(violations, "; ")
    )
  end

  defp category_bound(ctx) do
    agent = Context.agent!(ctx)
    outside = ctx.outside_category

    if "hcp:#{outside}:read" in agent.scopes,
      do: Assert.skip!("the agent's grant covers #{outside}, so no category outside it is known")

    response =
      Context.request(ctx, :post, Context.url(ctx, :search),
        token: agent.token,
        json: %{"query" => "conformance", "categories" => [outside], "purpose" => "HCP conformance check"}
      )

    Assert.problem!(response, 403, "scope-denied", "an agent searching #{outside}")
  end

  defp category_isolation(ctx) do
    agent = Context.agent!(ctx)
    other = ctx.second_category
    if "hcp:#{other}:read" in agent.scopes, do: Assert.skip!("the agent's grant also covers #{other}")
    word = Context.unique_word(ctx)

    outside =
      Fixtures.create!(ctx, Context.person!(ctx), category: other, preference: "Other category #{word}")

    Fixtures.create!(ctx, Context.person!(ctx), preference: "Granted category #{word}")
    body = Fixtures.search!(ctx, agent.token, %{"query" => word, "maxEntries" => 10})
    returned = body["entries"] || []

    Assert.check!(
      outside["id"] not in Fixtures.ids(body),
      "the agent received an entry from #{other}, outside its grant"
    )

    wrong =
      Enum.reject(
        returned,
        &("hcp:#{Envelope.get(&1, ctx.envelope_form, ["record", "category"])}:read" in agent.scopes)
      )

    Assert.check!(wrong == [], "the agent received #{length(wrong)} entries outside its scopes")
  end

  defp minimal_response(ctx) do
    word = Context.unique_word(ctx)
    preference = "Minimal mode statement #{word}"
    entry = Fixtures.create!(ctx, Context.person!(ctx), preference: preference)

    body =
      Fixtures.search!(ctx, Context.person!(ctx), %{"query" => word, "responseDetail" => "minimal"})

    found = Enum.find(body["entries"] || [], &(is_map(&1) and &1["id"] == entry["id"]))
    Assert.check!(found != nil, "the minimal search did not return the entry it matches")

    Assert.check!(
      found["value"] == preference,
      "a minimal entry must carry the preference content as \"value\""
    )

    Assert.check!(not Map.has_key?(found, "claim"), "a minimal entry must not carry the claim")

    Assert.check!(
      is_nil(Envelope.get(found, ctx.envelope_form, ["record", "provenance"])),
      "a minimal entry must not carry provenance"
    )
  end
end
