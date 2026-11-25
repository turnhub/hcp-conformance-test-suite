defmodule HcpConformance.V2.Checks.Mcp do
  @moduledoc """
  The MCP Binding (§10) over Streamable HTTP: how an HCP server identifies
  itself, the six tools that carry the context operations and nothing of the
  governance plane, and how Core errors are reported. A denial the host can act
  on is an HTTP challenge; one that depends on what is stored is a tool error,
  so that a challenge never shows an entry exists (§10.4).

  The checks that compare the two bindings, read an entry as the person, or read
  the audit log also need the HTTP Binding, which carries the governance plane.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.{Checks.Sharing, Fixtures, Mcp, Target}

  @binding "https://hcp.example/spec/bindings/mcp/2.0"
  @tools ~w(hcp_queryContext hcp_getEntry hcp_createEntry hcp_reviseEntry hcp_withdrawEntry hcp_reportSharing)
  # The fields each tool may expose: a subset of its Core operation's, never others (§1.5).
  @fields %{
    "hcp_queryContext" => ~w(query categories purpose purposeDescription maxEntries),
    "hcp_getEntry" => ~w(ref purpose purposeDescription version),
    "hcp_createEntry" =>
      ~w(categories dimension content declarationType confidence assertedBy sourceContext basis permittedPurposes relationships),
    "hcp_reviseEntry" =>
      ~w(ref expectedVersion content reason declarationType confidence assertedBy sourceContext basis permittedPurposes relationships),
    "hcp_withdrawEntry" => ~w(ref reason),
    "hcp_reportSharing" => ~w(recipient refs purpose sharedAt)
  }

  def group, do: "mcp"

  def checks do
    mcp = [requires: [:mcp]]
    agent = [requires: [:mcp, :agent]]
    hook = [requires: [:mcp, :hook]]
    both = [requires: [:mcp, :rest, :person, :agent]]
    governed = [requires: [:mcp, :rest, :person, :hook]]

    [
      Check.new(
        "mcp.discover",
        "10.2",
        :must,
        "server/discover announces the HCP extension, with the discovery document and the claims it repeats",
        &discover/1,
        mcp
      ),
      Check.new(
        "mcp.claims",
        "19.1",
        :must,
        "The extension points at the HCP discovery document, and the claims it repeats are ones that document makes",
        &claims/1,
        mcp
      ),
      Check.new(
        "mcp.tools",
        "10.3",
        :must,
        "tools/list offers the six HCP tools, each with an input schema",
        &tools/1,
        agent
      ),
      Check.new(
        "mcp.tool_fields",
        "1.5",
        :must,
        "Each tool exposes a subset of its Core operation's fields, and requires the ones Core requires",
        &tool_fields/1,
        agent
      ),
      Check.new(
        "mcp.no_governance_tools",
        "10.1",
        :must,
        "No HCP tool carries a governance operation, and withdrawal offers no hard delete",
        &no_governance/1,
        agent
      ),
      Check.new(
        "mcp.unauthenticated",
        "10.4",
        :must,
        "A tool call with missing or forged authorization is refused at the HTTP layer with 401",
        &unauthenticated/1,
        mcp
      ),
      Check.new(
        "mcp.query",
        "10.3.1",
        :must,
        "hcp_queryContext returns the query result in structuredContent, its entries as disclosures, and the same JSON as text",
        &query/1,
        agent
      ),
      Check.new(
        "mcp.get_entry",
        "10.3.2",
        :must,
        "hcp_getEntry returns the entry named by its ref, with a minimization report of none",
        &get_entry/1,
        agent
      ),
      Check.new(
        "mcp.create",
        "10.3.3",
        :must,
        "hcp_createEntry maps its fields onto the entry: content, categories, declaration type and source",
        &create/1,
        both
      ),
      Check.new(
        "mcp.revise",
        "10.3.4",
        :must,
        "hcp_reviseEntry creates version 2, and a stale expectedVersion is the tool error version-conflict",
        &revise/1,
        agent
      ),
      Check.new(
        "mcp.withdraw",
        "10.3.5",
        :must,
        "hcp_withdrawEntry withdraws the entry, which the client can then no longer read",
        &withdraw/1,
        agent
      ),
      Check.new(
        "mcp.report_sharing",
        "10.3.6",
        :must,
        "hcp_reportSharing reports a share, which the provider records as context.shared",
        &report_sharing/1,
        governed
      ),
      Check.new(
        "mcp.invalid_request",
        "10.4",
        :must,
        "Invalid request is a tool execution error carrying malformed-request, in structuredContent and as text",
        &invalid_request/1,
        agent
      ),
      Check.new(
        "mcp.unknown_tool",
        "10.4",
        :must,
        "An unknown tool is a JSON-RPC protocol error, not a tool result",
        &unknown_tool/1,
        agent
      ),
      Check.new(
        "mcp.category_challenge",
        "10.4",
        :must,
        "A category the grant does not cover is refused with 403 and an insufficient_scope challenge naming the scope needed",
        &category_challenge/1,
        agent
      ),
      Check.new(
        "mcp.purpose_challenge",
        "10.4",
        :must,
        "A purpose the grant did not approve is refused with 403 and a challenge whose description names the purpose code",
        &purpose_challenge/1,
        agent
      ),
      Check.new(
        "mcp.write_challenge",
        "10.4",
        :must,
        "A create under a read-only grant is refused with 403 and a challenge naming the write scope",
        &write_challenge/1,
        hook
      ),
      Check.new(
        "mcp.existence_hidden",
        "10.4",
        :must,
        "An entry that does not exist, or belongs to another grant, is the tool error scope-denied, never a challenge",
        &existence_hidden/1,
        hook
      ),
      Check.new(
        "mcp.same_grant",
        "3.11",
        :must,
        "One grant is enforced on both bindings: a ref disclosed over one names the same entry over the other",
        &same_grant/1,
        both
      ),
      Check.new(
        "mcp.revocation",
        "6.2.2",
        :must,
        "Revocation by the person cuts off the client's very next tool call",
        &revocation/1,
        governed
      ),
      Check.new(
        "mcp.audited",
        "8.1",
        :must,
        "A query over MCP appends context.read with its retrievalId and purpose, as over HTTP",
        &audited/1,
        both
      ),
      Check.new(
        "mcp.token_not_returned",
        "10.5",
        :must,
        "The access token is never returned as tool content",
        &token_not_returned/1,
        agent
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)
  defp agent(ctx), do: Context.agent!(ctx).token

  defp rpc!(ctx, token, method) do
    case Mcp.request(ctx, token, method) do
      {%{status: 200}, %{"result" => %{} = result}} ->
        result

      {response, _message} ->
        Assert.fail!(
          "#{method}: expected a JSON-RPC result, got HTTP #{response.status}#{Assert.body_hint(response)}"
        )
    end
  end

  defp extension!(ctx) do
    settings =
      get_in(rpc!(ctx, ctx.agent && ctx.agent.token, "server/discover"), [
        "capabilities",
        "extensions",
        Mcp.extension()
      ])

    Assert.check!(
      is_map(settings),
      "server/discover does not announce the extension #{Mcp.extension()} in capabilities.extensions"
    )

    settings
  end

  defp discover(ctx) do
    result = rpc!(ctx, ctx.agent && ctx.agent.token, "server/discover")

    Assert.check!(
      is_map(get_in(result, ["capabilities", "tools"])),
      "server/discover must declare the tools capability"
    )

    settings = extension!(ctx)

    Assert.check!(
      is_binary(settings["discovery"]),
      "the extension must carry the URL of the discovery document"
    )

    Assert.check!(
      is_list(settings["conformsTo"]) and @binding in settings["conformsTo"],
      "the extension must repeat the conformance claims, the MCP Binding's among them"
    )
  end

  defp claims(ctx) do
    settings = extension!(ctx)
    response = Context.request(ctx, :get, to_string(settings["discovery"]))
    Assert.status!(response, 200, "GET the discovery document the extension points at")
    document = Assert.json_object!(response, "the discovery document the extension points at")
    published = List.wrap(document["conformsTo"])

    Assert.check!(
      document["provider"] == (ctx.discovery || %{})["provider"],
      "the extension points at another provider's discovery document"
    )

    extra = List.wrap(settings["conformsTo"]) -- published

    Assert.check!(
      extra == [],
      "the extension claims what the discovery document does not: #{Enum.join(extra, ", ")}"
    )

    Assert.check!(
      @binding in published and "mcp" in List.wrap(document["bindings"]),
      "the discovery document must claim and list the MCP Binding"
    )
  end

  defp listed!(ctx) do
    tools = rpc!(ctx, agent(ctx), "tools/list")["tools"]
    Assert.check!(is_list(tools), "tools/list: the result has no tools array")
    Map.new(for %{"name" => name} = tool <- tools, do: {name, tool})
  end

  defp tools(ctx) do
    listed = listed!(ctx)
    missing = @tools -- Map.keys(listed)
    # A provider may list only the tools the grant permits (§10.3); the default
    # grant reads and writes, so only reporting a share may be left out.
    Assert.check!(
      missing -- ["hcp_reportSharing"] == [],
      "tools/list lacks #{Enum.join(missing, ", ")}"
    )

    unschematized =
      for name <- @tools,
          tool = listed[name],
          not is_map(get_in(tool, ["inputSchema", "properties"])),
          do: name

    Assert.check!(
      unschematized == [],
      "no inputSchema with properties: #{Enum.join(unschematized, ", ")}"
    )
  end

  defp tool_fields(ctx) do
    listed = listed!(ctx)

    problems =
      for {name, allowed} <- @fields,
          tool = listed[name],
          problem <- field_problems(name, tool["inputSchema"] || %{}, allowed) do
        problem
      end

    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  # What every caller of the Core operation must say, the tool must require.
  @required %{
    "hcp_queryContext" => ~w(query purpose),
    "hcp_getEntry" => ~w(ref purpose),
    "hcp_createEntry" => ~w(categories content declarationType),
    "hcp_reviseEntry" => ~w(ref expectedVersion content reason),
    "hcp_withdrawEntry" => ~w(ref reason),
    "hcp_reportSharing" => ~w(recipient refs purpose sharedAt)
  }

  defp field_problems(name, schema, allowed) do
    exposed = Map.keys(schema["properties"] || %{})
    others = exposed -- allowed
    unrequired = @required[name] -- List.wrap(schema["required"])

    for {true, message} <- [
          {others != [],
           "#{name} exposes fields its Core operation does not have: #{Enum.join(others, ", ")}"},
          {unrequired != [], "#{name} does not require #{Enum.join(unrequired, ", ")}"}
        ],
        do: message
  end

  defp no_governance(ctx) do
    listed = listed!(ctx)

    others =
      for name <- Map.keys(listed),
          String.starts_with?(name, "hcp_"),
          name not in @tools,
          do: name

    Assert.check!(
      others == [],
      "HCP tools beyond the context operations: #{Enum.join(others, ", ")}"
    )

    hard = get_in(listed, ["hcp_withdrawEntry", "inputSchema", "properties", "hardDelete"])

    Assert.check!(
      is_nil(hard),
      "hcp_withdrawEntry offers hardDelete, which is a governance operation"
    )
  end

  defp query_arguments(ctx, extra \\ %{}),
    do:
      Map.merge(
        %{
          "query" => "conformance",
          "categories" => [ctx.primary_category],
          "purpose" => Target.purpose()
        },
        extra
      )

  defp unauthenticated(ctx) do
    for {token, what} <- [
          {nil, "no authorization"},
          {"hcp-conformance-forged-" <> Context.random_word(24), "a forged token"}
        ] do
      case Mcp.call(ctx, token, "hcp_queryContext", query_arguments(ctx)) do
        {:http, %{status: 401}} ->
          :ok

        other ->
          Assert.fail!("a tool call with #{what}: expected HTTP 401, got #{Mcp.describe(other)}")
      end
    end
  end

  # An entry the client itself wrote over MCP, so these checks need nothing but
  # the binding: its unique word, and the ref it was disclosed with.
  defp written!(ctx) do
    word = Context.unique_word(ctx)
    arguments = create_arguments(ctx, "I prefer " <> word)
    {word, Mcp.call!(ctx, agent(ctx), "hcp_createEntry", arguments)["ref"]}
  end

  # An entry the person wrote over HTTP, for the checks that compare the two sides.
  defp seeded!(ctx) do
    word = Context.unique_word(ctx)
    entry = Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)
    {word, entry}
  end

  defp found!(ctx, word) do
    case Mcp.call!(ctx, agent(ctx), "hcp_queryContext", query_arguments(ctx, %{"query" => word}))[
           "entries"
         ] do
      [disclosure] when is_map(disclosure) ->
        disclosure

      other ->
        Assert.fail!(
          "hcp_queryContext: expected the one entry just written, got #{inspect(other && length(other))}"
        )
    end
  end

  defp query(ctx) do
    {word, ref} = written!(ctx)

    {:ok, result} =
      expect_ok(
        Mcp.call(ctx, agent(ctx), "hcp_queryContext", query_arguments(ctx, %{"query" => word})),
        "hcp_queryContext"
      )

    structured = result["structuredContent"]

    Assert.check!(is_map(structured), "the result must be returned in structuredContent")

    Assert.check!(
      match?([%{"ref" => ^ref}], structured["entries"]),
      "entries must hold the one disclosure, named by the ref the grant already knows it by"
    )

    [disclosure] = structured["entries"]
    withheld = Enum.filter(~w(id subject record), &Map.has_key?(disclosure, &1))

    Assert.check!(
      withheld == [],
      "the disclosure carries #{Enum.join(withheld, ", ")}; the model receives no stable entry identifier"
    )

    missing =
      Enum.reject(
        ~w(retrievalId minimization categoriesSearched timestamp),
        &Map.has_key?(structured, &1)
      )

    Assert.check!(missing == [], "the result lacks #{Enum.join(missing, ", ")}")

    text =
      for %{"type" => "text", "text" => text} <- List.wrap(result["content"]),
          do: Jason.decode(text)

    Assert.check!(
      {:ok, structured} in text,
      "the serialized JSON must also be returned in a text content block"
    )
  end

  defp expect_ok({:ok, _result} = reply, _tool), do: reply

  defp expect_ok(reply, tool),
    do: Assert.fail!("#{tool}: expected a tool result, got #{Mcp.describe(reply)}")

  defp get_entry(ctx) do
    {_word, ref} = written!(ctx)

    result =
      Mcp.call!(ctx, agent(ctx), "hcp_getEntry", %{"ref" => ref, "purpose" => Target.purpose()})

    Assert.check!(
      get_in(result, ["entry", "ref"]) == ref,
      "the result's entry is not the one named"
    )

    Assert.check!(
      get_in(result, ["minimization", "method"]) == "none",
      "a get-entry result reports minimization.method as none"
    )
  end

  defp create_arguments(ctx, text, extra \\ %{}) do
    Map.merge(
      %{
        "categories" => [ctx.primary_category],
        "content" => text,
        "declarationType" => "person-declared",
        "sourceContext" => "conversation-id:hcp-conformance-" <> ctx.nonce
      },
      extra
    )
  end

  defp create(ctx) do
    word = Context.unique_word(ctx)

    disclosure =
      Mcp.call!(
        ctx,
        agent(ctx),
        "hcp_createEntry",
        create_arguments(ctx, "I prefer " <> word, %{"dimension" => "mcp_check"})
      )

    Assert.check!(
      is_binary(disclosure["ref"]) and not Map.has_key?(disclosure, "id"),
      "the created entry is returned as a disclosure carrying its new ref"
    )

    stored =
      ctx
      |> Fixtures.query!(person(ctx), %{"query" => word, "maxEntries" => 20})
      |> Map.fetch!("entries")
      |> Enum.find(&(get_in(&1, ["content", "value"]) == "I prefer " <> word)) ||
        Assert.fail!("the person cannot find the entry the tool created")

    problems =
      for {false, message} <- [
            {get_in(stored, ["classification", "categories"]) == [ctx.primary_category],
             "categories is not classification.categories"},
            {get_in(stored, ["classification", "dimension"]) == "mcp_check",
             "dimension is not classification.dimension"},
            {get_in(stored, ["assertion", "declarationType"]) == "person-declared",
             "declarationType is not assertion.declarationType"},
            {get_in(stored, ["record", "provenance", "source"]) ==
               "conversation-id:hcp-conformance-" <> ctx.nonce,
             "sourceContext is not record.provenance.source"},
            {get_in(stored, ["record", "provenance", "assertedBy", "assurance"]) == "unverified",
             "a Context Client's person-declared entry is not recorded as unverified"}
          ],
          do: message

    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  defp revise(ctx) do
    ref =
      Mcp.call!(
        ctx,
        agent(ctx),
        "hcp_createEntry",
        create_arguments(ctx, "Statement " <> Context.unique_word(ctx))
      )["ref"]

    arguments = %{
      "ref" => ref,
      "expectedVersion" => 1,
      "content" => "Revised " <> Context.unique_word(ctx),
      "reason" => "HCP conformance check"
    }

    revised = Mcp.call!(ctx, agent(ctx), "hcp_reviseEntry", arguments)

    Assert.check!(
      revised["version"] == 2 and revised["ref"] == ref,
      "a revision keeps the ref and increments the version to 2"
    )

    ctx
    |> Mcp.call(agent(ctx), "hcp_reviseEntry", arguments)
    |> Mcp.tool_error!("version-conflict", "a revision naming a stale expectedVersion")
  end

  defp withdraw(ctx) do
    ref =
      Mcp.call!(
        ctx,
        agent(ctx),
        "hcp_createEntry",
        create_arguments(ctx, "Statement " <> Context.unique_word(ctx))
      )["ref"]

    result =
      Mcp.call!(ctx, agent(ctx), "hcp_withdrawEntry", %{
        "ref" => ref,
        "reason" => "HCP conformance check"
      })

    Assert.check!(
      result["status"] == "deleted" and result["ref"] == ref,
      "the result names the entry by its ref, as deleted"
    )

    ctx
    |> Mcp.call(agent(ctx), "hcp_getEntry", %{"ref" => ref, "purpose" => Target.purpose()})
    |> Mcp.tool_error!("scope-denied", "reading a withdrawn entry")
  end

  defp report_sharing(ctx) do
    word = Context.unique_word(ctx)
    entry = Fixtures.create!(ctx, person(ctx), value: "I wear size " <> word)

    grant =
      case Context.issue_grant(ctx, actions: ["read"], onward_sharing: %{}) do
        {:ok, grant} ->
          grant

        {:error, message} ->
          Assert.skip!("the implementation issues no grant with onwardSharing: " <> message)
      end

    [disclosure] =
      Mcp.call!(ctx, grant.token, "hcp_queryContext", query_arguments(ctx, %{"query" => word}))[
        "entries"
      ]

    expect_ok(
      Mcp.call(ctx, grant.token, "hcp_reportSharing", Sharing.share_body([disclosure["ref"]])),
      "hcp_reportSharing"
    )

    Sharing.shared_event!(ctx, entry["id"], true)
  end

  defp invalid_request(ctx) do
    arguments =
      create_arguments(ctx, "Inferred statement", %{
        "declarationType" => "model-inferred",
        "assertedBy" => "model:hcp-conformance"
      })

    reply = Mcp.call(ctx, agent(ctx), "hcp_createEntry", arguments)

    error =
      Mcp.tool_error!(reply, "malformed-request", "a model-inferred create without confidence")

    {:tool_error, result} = reply
    texts = for %{"type" => "text", "text" => text} <- List.wrap(result["content"]), do: text

    Assert.check!(
      Enum.any?(texts, &String.contains?(&1, error["type"])),
      "the error must also be given in a text content block"
    )
  end

  defp unknown_tool(ctx) do
    case Mcp.call(ctx, agent(ctx), "hcp_conformanceNoSuchTool", %{}) do
      {:rpc_error, _error} ->
        :ok

      other ->
        Assert.fail!("an unknown tool: expected a JSON-RPC error, got #{Mcp.describe(other)}")
    end
  end

  defp challenge!(reply, what) do
    case reply do
      {:http, %{status: 403} = response} ->
        challenge = Mcp.challenge(response)

        Assert.check!(
          challenge["error"] == "insufficient_scope",
          "#{what}: the 403 must carry a WWW-Authenticate Bearer challenge with error=\"insufficient_scope\""
        )

        challenge

      other ->
        Assert.fail!(
          "#{what}: expected HTTP 403 with a challenge, which reaches the host that holds the grant; got #{Mcp.describe(other)}"
        )
    end
  end

  defp category_challenge(ctx) do
    reply =
      Mcp.call(
        ctx,
        agent(ctx),
        "hcp_queryContext",
        query_arguments(ctx, %{"categories" => [ctx.outside_category]})
      )

    scope = challenge!(reply, "a query in a category outside the grant")["scope"] || ""
    needed = "hcp:#{ctx.outside_category}:read"

    Assert.check!(
      needed in String.split(scope),
      "the challenge's scope must name #{needed}, got #{inspect(scope)}"
    )
  end

  defp purpose_challenge(ctx) do
    reply =
      Mcp.call(
        ctx,
        agent(ctx),
        "hcp_queryContext",
        query_arguments(ctx, %{"purpose" => Target.other_purpose()})
      )

    description =
      challenge!(reply, "a query for a purpose the grant did not approve")["error_description"] ||
        ""

    Assert.check!(
      String.contains?(description, Target.other_purpose()),
      "error_description must name the purpose code the request used, got #{inspect(description)}"
    )
  end

  defp write_challenge(ctx) do
    grant = Context.issue_grant!(ctx, actions: ["read"])

    reply =
      Mcp.call(
        ctx,
        grant.token,
        "hcp_createEntry",
        create_arguments(ctx, "Statement " <> Context.unique_word(ctx))
      )

    scope = challenge!(reply, "a create under a read-only grant")["scope"] || ""
    needed = "hcp:#{ctx.primary_category}:write"

    Assert.check!(
      needed in String.split(scope),
      "the challenge's scope must name #{needed}, got #{inspect(scope)}"
    )
  end

  defp existence_hidden(ctx) do
    mine = Context.issue_grant!(ctx, actions: ["read", "write"])
    other = Context.issue_grant!(ctx, actions: ["read", "write"])

    theirs =
      Mcp.call!(
        ctx,
        other.token,
        "hcp_createEntry",
        create_arguments(ctx, "Statement " <> Context.unique_word(ctx))
      )["ref"]

    for {ref, what} <- [
          {"r_" <> Context.random_word(14), "an entry that does not exist"},
          {theirs, "a ref that belongs to another grant"}
        ] do
      ctx
      |> Mcp.call(mine.token, "hcp_getEntry", %{"ref" => ref, "purpose" => Target.purpose()})
      |> Mcp.tool_error!("scope-denied", what)
    end
  end

  defp same_grant(ctx) do
    {word, _entry} = seeded!(ctx)
    [over_http] = Fixtures.found(ctx, agent(ctx), word)
    over_mcp = found!(ctx, word)

    Assert.check!(
      over_http["ref"] == over_mcp["ref"],
      "one grant was given two refs for one entry, one on each binding"
    )

    Assert.status!(
      Fixtures.get(ctx, agent(ctx), over_mcp["ref"]),
      200,
      "reading over HTTP an entry by the ref disclosed over MCP"
    )
  end

  defp revocation(ctx) do
    grant = Context.issue_grant!(ctx, actions: ["read"])
    Mcp.call!(ctx, grant.token, "hcp_queryContext", query_arguments(ctx))

    response =
      Context.request(ctx, :delete, Context.grant_url(ctx, grant.grant_id), token: person(ctx))

    Assert.status!(response, 204, "DELETE /v2/grants/{grantId}")

    case Mcp.call(ctx, grant.token, "hcp_queryContext", query_arguments(ctx)) do
      {:http, %{status: status}} when status in [401, 403] ->
        :ok

      other ->
        Assert.fail!(
          "after revocation: expected the tool call to be refused with 401 or 403, got #{Mcp.describe(other)}"
        )
    end
  end

  defp audited(ctx) do
    {word, entry} = seeded!(ctx)

    result =
      Mcp.call!(ctx, agent(ctx), "hcp_queryContext", query_arguments(ctx, %{"query" => word}))

    match = fn event ->
      AuditLog.event?(event, "context.read", purpose: Target.purpose()) and
        get_in(event, ["participants", "retrievalId"]) == result["retrievalId"]
    end

    [event | _] =
      AuditLog.await!(ctx, "context.read carrying the tool result's retrievalId", match,
        read?: true
      )

    disclosed = for %{"entryId" => id} <- List.wrap(event["disclosed"]), do: id

    Assert.check!(
      disclosed == [entry["id"]],
      "the event must list the entry disclosed, by its id"
    )
  end

  defp token_not_returned(ctx) do
    token = agent(ctx)

    replies = [
      Mcp.request(ctx, token, "tools/list"),
      Mcp.request(ctx, token, "tools/call", %{
        "name" => "hcp_queryContext",
        "arguments" => query_arguments(ctx)
      })
    ]

    leaked =
      Enum.any?(replies, fn {response, _message} ->
        String.contains?(response.body || "", token)
      end)

    Assert.check!(not leaked, "a response of the MCP endpoint carries the access token")
  end
end
