defmodule HcpConformance.V2.Checks.Query do
  @moduledoc """
  Query (§5.2.1) and the minimization contract it carries (§7): the category and
  purpose bound, the quantity bound, relevance ordering, and a report that
  discloses no measure of what was withheld.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.{Fixtures, Target}

  @count_members ~w(total totalCount count available considered matched withheld remaining totalEntries
                    entriesConsidered entriesAvailable hasMore)
  @paging_members ~w(nextCursor cursor next page nextPage)

  def group, do: "query"

  def checks do
    person = [requires: [:rest, :person]]
    agent = [requires: [:rest, :person, :agent]]

    [
      Check.new(
        "query.response",
        "9.4.1",
        :must,
        "A query answers 200 with entries, retrievalId, minimization, categoriesSearched and timestamp",
        &response/1,
        person
      ),
      Check.new(
        "query.requires_purpose",
        "5.2.1",
        :must,
        "A query without a purpose is rejected with 422 malformed-request",
        &requires_purpose/1,
        person
      ),
      Check.new(
        "query.purpose_bound",
        "6.1.5.2",
        :must,
        "A query naming a purpose the grant did not approve fails with 403 scope-denied",
        &purpose_bound/1,
        agent
      ),
      Check.new(
        "query.method_declared",
        "7.3",
        :must,
        "minimization.method matches the method declared in the discovery document",
        &method_declared/1,
        person
      ),
      Check.new(
        "query.default_max",
        "5.2.1",
        :must,
        "Without maxEntries a query returns at most 5 entries",
        &default_max/1,
        person
      ),
      Check.new(
        "query.ceiling",
        "7.2",
        :must,
        "A query never returns more than 20 entries, whatever maxEntries asks for",
        &ceiling/1,
        person
      ),
      Check.new(
        "query.not_padded",
        "7.2",
        :must,
        "A query does not pad its results to reach maxEntries",
        &not_padded/1,
        person
      ),
      Check.new(
        "query.relevance_order",
        "7.3",
        :must,
        "Lexical ordering ranks the entry sharing more query terms first",
        &relevance_order/1,
        person
      ),
      Check.new(
        "query.no_counts",
        "7.5",
        :must,
        "The result discloses no count of entries considered, available or withheld",
        &no_counts/1,
        person
      ),
      Check.new(
        "query.not_paginated",
        "9.5",
        :must,
        "Query results are not paginated",
        &not_paginated/1,
        person
      ),
      Check.new(
        "query.audited",
        "8.2",
        :must,
        "A query appends context.read with the purpose, the retrievalId and each entry disclosed",
        &audited/1,
        agent
      ),
      Check.new(
        "query.text_not_logged",
        "8.2",
        :must,
        "The query text is not recorded in the audit log",
        &text_not_logged/1,
        person
      ),
      Check.new(
        "query.category_bound",
        "5.2.1",
        :must,
        "A Context Client querying a category outside its grant is refused with 403 scope-denied",
        &category_bound/1,
        agent
      ),
      Check.new(
        "query.category_isolation",
        "7.1",
        :must,
        "A Context Client's results never include entries from categories its grant does not cover",
        &category_isolation/1,
        requires: [:rest, :person, :agent, :second_category]
      ),
      Check.new(
        "query.default_categories",
        "5.2.1",
        :must,
        "A query naming no categories searches those the grant can read, and says which",
        &default_categories/1,
        agent
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)
  defp agent(ctx), do: Context.agent!(ctx).token

  defp seed!(ctx, word, count) do
    for index <- 1..count,
        do: Fixtures.create!(ctx, person(ctx), value: "Seeded #{word} statement number #{index}")
  end

  defp response(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, word, 1)
    result = Fixtures.query!(ctx, person(ctx), %{"query" => word})

    problems =
      for {false, message} <- [
            {Fixtures.urn_uuid?(result["retrievalId"]), "retrievalId must be a urn:uuid"},
            {is_binary(get_in(result, ["minimization", "method"])),
             "minimization.method is required"},
            {result["categoriesSearched"] == [ctx.primary_category],
             "categoriesSearched must list the categories named"},
            {Fixtures.date_time?(result["timestamp"]), "timestamp must be a date-time"},
            {length(result["entries"]) == 1,
             "the query for a unique word should return the one entry carrying it"}
          ],
          do: message

    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  defp requires_purpose(ctx) do
    body = %{"query" => "conformance", "categories" => [ctx.primary_category]}

    response =
      Context.request(ctx, :post, Context.url(ctx, :query), token: person(ctx), json: body)

    Assert.problem!(response, 422, "malformed-request", "a query without a purpose")
  end

  defp purpose_bound(ctx) do
    response =
      Fixtures.query(ctx, agent(ctx), %{
        "query" => "conformance",
        "purpose" => Target.other_purpose()
      })

    Assert.problem!(
      response,
      403,
      "scope-denied",
      "a query for a purpose the grant did not approve"
    )
  end

  defp method_declared(ctx) do
    declared = (ctx.discovery || %{})["minimization_method"]
    result = Fixtures.query!(ctx, person(ctx), %{"query" => "conformance"})
    method = get_in(result, ["minimization", "method"])

    Assert.check!(
      method == declared,
      "minimization.method is #{inspect(method)}, the discovery document declares #{inspect(declared)}"
    )
  end

  defp default_max(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, word, 7)
    count = length(Fixtures.query!(ctx, person(ctx), %{"query" => word})["entries"])
    Assert.check!(count <= 5, "a query without maxEntries returned #{count} entries")
    Assert.check!(count > 0, "the query returned none of the 7 entries carrying its only term")
  end

  defp ceiling(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, word, 22)

    count =
      length(Fixtures.query!(ctx, person(ctx), %{"query" => word, "maxEntries" => 50})["entries"])

    Assert.check!(count <= 20, "maxEntries 50 returned #{count} entries, above the ceiling of 20")
  end

  defp not_padded(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, word, 2)
    seed!(ctx, Context.unique_word(ctx), 4)
    result = Fixtures.query!(ctx, person(ctx), %{"query" => word, "maxEntries" => 10})
    others = Enum.reject(Fixtures.values(result), &(is_binary(&1) and String.contains?(&1, word)))

    Assert.check!(
      others == [],
      "#{length(others)} entries that do not carry the query's only term were returned to fill maxEntries"
    )
  end

  defp relevance_order(ctx) do
    method = (ctx.discovery || %{})["minimization_method"]

    if method != "lexical" do
      Assert.skip!(
        "ordering is only predictable for the lexical method; #{inspect(method)} is taken on declaration (§7)"
      )
    end

    [a, b, c] = for _ <- 1..3, do: Context.unique_word(ctx)
    Fixtures.create!(ctx, person(ctx), value: "Statement about #{a} only")
    Fixtures.create!(ctx, person(ctx), value: "Statement about #{a} and #{b} and #{c}")
    Fixtures.create!(ctx, person(ctx), value: "Statement about #{a} and #{b}")

    values =
      ctx
      |> Fixtures.query!(person(ctx), %{"query" => "#{a} #{b} #{c}", "maxEntries" => 3})
      |> Fixtures.values()

    counts =
      Enum.map(values, fn value ->
        Enum.count([a, b, c], &String.contains?(to_string(value), &1))
      end)

    Assert.check!(
      counts == [3, 2, 1],
      "entries sharing #{inspect(counts)} query terms were returned in that order, expected [3, 2, 1]"
    )
  end

  defp no_counts(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, word, 3)
    result = Fixtures.query!(ctx, person(ctx), %{"query" => word, "maxEntries" => 1})

    leaked =
      Enum.filter(
        @count_members,
        &(Map.has_key?(result, &1) or Map.has_key?(result["minimization"] || %{}, &1))
      )

    Assert.check!(leaked == [], "the result carries #{Enum.join(leaked, ", ")}")
  end

  defp not_paginated(ctx) do
    word = Context.unique_word(ctx)
    seed!(ctx, word, 3)
    result = Fixtures.query!(ctx, person(ctx), %{"query" => word, "maxEntries" => 1})
    paging = Enum.filter(@paging_members, &(result[&1] not in [nil, false]))

    Assert.check!(
      paging == [],
      "the result carries pagination members: #{Enum.join(paging, ", ")}"
    )
  end

  defp audited(ctx) do
    word = Context.unique_word(ctx)
    entry = Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)

    result =
      Fixtures.query!(ctx, agent(ctx), %{
        "query" => word,
        "purposeDescription" => "HCP conformance"
      })

    match = fn event ->
      AuditLog.event?(event, "context.read", purpose: Target.purpose()) and
        get_in(event, ["participants", "retrievalId"]) == result["retrievalId"]
    end

    [event | _] =
      AuditLog.await!(ctx, "context.read carrying the query's retrievalId", match, read?: true)

    disclosed = for %{"entryId" => id} = item <- List.wrap(event["disclosed"]), do: {id, item}

    Assert.check!(
      Enum.map(disclosed, &elem(&1, 0)) == [entry["id"]],
      "disclosed must list the entry returned, by its id"
    )

    [{_id, item}] = disclosed

    Assert.check!(
      item["version"] == 1 and Fixtures.date_time?(item["useUntil"]),
      "each disclosed item carries the version and the useUntil given"
    )

    Assert.check!(
      event["grantId"] == Context.agent!(ctx).grant_id,
      "the event must name the grant the client acted under"
    )
  end

  defp text_not_logged(ctx) do
    word = Context.unique_word(ctx)
    Fixtures.query!(ctx, person(ctx), %{"query" => "looking for " <> word})
    AuditLog.await!(ctx, "context.read", &AuditLog.event?(&1, "context.read"), read?: true)
    logged = ctx |> AuditLog.fetch!() |> Enum.filter(&String.contains?(Jason.encode!(&1), word))
    Assert.check!(logged == [], "#{length(logged)} audit events carry the query text")
  end

  defp category_bound(ctx) do
    response =
      Fixtures.query(ctx, agent(ctx), %{
        "query" => "conformance",
        "categories" => [ctx.outside_category]
      })

    Assert.problem!(response, 403, "scope-denied", "a query in a category outside the grant")
  end

  defp category_isolation(ctx) do
    word = Context.unique_word(ctx)
    Fixtures.create!(ctx, person(ctx), value: "Inside #{word}")

    Fixtures.create!(ctx, person(ctx),
      value: "Outside #{word}",
      categories: [ctx.second_category]
    )

    values =
      ctx
      |> Fixtures.query!(agent(ctx), %{"query" => word, "maxEntries" => 20})
      |> Fixtures.values()

    Assert.check!(
      values == ["Inside #{word}"],
      "expected only the entry in #{ctx.primary_category}, got #{inspect(values)}"
    )
  end

  defp default_categories(ctx) do
    body = %{"query" => "conformance", "purpose" => Target.purpose()}

    response =
      Context.request(ctx, :post, Context.url(ctx, :query), token: agent(ctx), json: body)

    Assert.status!(response, 200, "a query naming no categories")
    searched = Assert.json_object!(response, "a query naming no categories")["categoriesSearched"]

    readable =
      for "hcp:" <> rest <- Context.agent!(ctx).scopes,
          [category, "read"] <- [String.split(rest, ":")],
          do: category

    Assert.check!(
      is_list(searched) and Enum.sort(searched) == Enum.sort(readable),
      "categoriesSearched is #{inspect(searched)}; the grant reads #{inspect(readable)} for this purpose"
    )
  end
end
