defmodule HcpConformance.V2.Checks.Rules do
  @moduledoc """
  Standing rules (§6.3) and directives (§6.4): what the person sets once for
  every grant. A rule denies named Client Operators some or all categories, on
  existing and future grants; a directive is delivered with every disclosure it
  applies to.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.Fixtures

  def group, do: "rules"

  def checks do
    person = [requires: [:rest, :person]]
    hook = [requires: [:rest, :person, :hook]]

    [
      Check.new(
        "rules.set",
        "9.4.14",
        :must,
        "POST /v2/rules answers 201 with the rule, its ruleId and createdAt, and effect deny; the rule is then listed",
        &set_rule/1,
        person
      ),
      Check.new(
        "rules.audited",
        "6.3",
        :must,
        "Setting and removing a standing rule append rule.set and rule.removed",
        &rule_audited/1,
        person
      ),
      Check.new(
        "rules.needs_target",
        "6.3",
        :must,
        "A standing rule naming neither operators nor requires is refused",
        &needs_target/1,
        person
      ),
      Check.new(
        "rules.enforced",
        "6.3",
        :must,
        "A standing rule applies to an existing grant from the moment it is set",
        &enforced/1,
        hook
      ),
      Check.new(
        "rules.blocks_issuance",
        "6.3",
        :must,
        "No grant is issued that reaches a category a standing rule denies its Client Operator",
        &blocks_issuance/1,
        hook
      ),
      Check.new(
        "rules.other_operators_unaffected",
        "6.3",
        :must,
        "A standing rule naming one operator leaves other operators' clients alone",
        &others_unaffected/1,
        hook
      ),
      Check.new(
        "directives.set",
        "9.4.15",
        :must,
        "POST /v2/directives answers 201 with the directive, its directiveId and createdAt; it is then listed",
        &set_directive/1,
        person
      ),
      Check.new(
        "directives.audited",
        "6.4",
        :must,
        "Setting and removing a directive append directive.set and directive.removed",
        &directive_audited/1,
        person
      ),
      Check.new(
        "directives.delivered",
        "6.4",
        :must,
        "A query result to a Context Client carries each directive that applies, and context.read records which",
        &delivered/1,
        requires: [:rest, :person, :agent]
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)

  defp post!(ctx, endpoint, body) do
    response =
      Context.request(ctx, :post, Context.url(ctx, endpoint), token: person(ctx), json: body)

    Assert.status!(response, 201, "POST /v2/#{endpoint}")
    Assert.json_object!(response, "POST /v2/#{endpoint}")
  end

  defp listed(ctx, endpoint) do
    response = Context.request(ctx, :get, Context.url(ctx, endpoint), token: person(ctx))
    Assert.status!(response, 200, "GET /v2/#{endpoint}")
    items = Assert.json_object!(response, "GET /v2/#{endpoint}")[to_string(endpoint)]
    Assert.check!(is_list(items), "GET /v2/#{endpoint}: the body has no #{endpoint} array")
    items
  end

  defp remove!(ctx, endpoint, id) do
    url =
      Context.url(ctx, endpoint) <> "/" <> URI.encode(id, &(URI.char_unreserved?(&1) or &1 == ?:))

    Assert.status!(
      Context.request(ctx, :delete, url, token: person(ctx)),
      204,
      "DELETE /v2/#{endpoint}/{id}"
    )
  end

  # A standing rule outlives the check that set it and would deny later checks'
  # clients, so every rule a check sets is removed again, pass or fail.
  defp with_rule(ctx, body, fun) do
    rule = post!(ctx, :rules, body)
    Assert.check!(is_binary(rule["ruleId"]), "the rule carries no ruleId")

    try do
      fun.(rule)
    after
      Context.request(ctx, :delete, Context.url(ctx, :rules) <> "/" <> rule["ruleId"],
        token: person(ctx)
      )
    end
  end

  defp operator(ctx) do
    domain = "op-#{Context.random_word(8)}.conformance.hcp.example"
    {domain, %{"id" => "https://#{domain}", "name" => "Conformance operator " <> ctx.nonce}}
  end

  defp set_rule(ctx) do
    {domain, _operator} = operator(ctx)

    with_rule(ctx, %{"operators" => [domain], "categories" => [ctx.primary_category]}, fn rule ->
      Assert.check!(
        rule["effect"] == "deny",
        "effect must be deny, got #{inspect(rule["effect"])}"
      )

      Assert.check!(Fixtures.date_time?(rule["createdAt"]), "createdAt must be a date-time")
      Assert.check!(rule["operators"] == [domain], "the rule does not carry its operators")

      Assert.check!(
        Enum.any?(listed(ctx, :rules), &(&1["ruleId"] == rule["ruleId"])),
        "GET /v2/rules does not list the rule"
      )
    end)
  end

  defp rule_audited(ctx) do
    {domain, _operator} = operator(ctx)
    rule = post!(ctx, :rules, %{"operators" => [domain]})
    remove!(ctx, :rules, rule["ruleId"])

    for type <- ["rule.set", "rule.removed"] do
      AuditLog.await!(
        ctx,
        type,
        &(AuditLog.event?(&1, type) and get_in(&1, ["data", "ruleId"]) == rule["ruleId"])
      )
    end

    Assert.check!(
      not Enum.any?(listed(ctx, :rules), &(&1["ruleId"] == rule["ruleId"])),
      "the removed rule is still listed"
    )
  end

  defp needs_target(ctx) do
    response =
      Context.request(ctx, :post, Context.url(ctx, :rules),
        token: person(ctx),
        json: %{"categories" => [ctx.primary_category]}
      )

    if response.status == 201 and is_map(response.json) and is_binary(response.json["ruleId"]),
      do: remove!(ctx, :rules, response.json["ruleId"])

    Assert.refused!(response, "a standing rule naming neither operators nor requires")
  end

  defp enforced(ctx) do
    {domain, operator} = operator(ctx)
    grant = Context.issue_grant!(ctx, actions: ["read"], operator: operator)
    Fixtures.query!(ctx, grant.token, %{"query" => "conformance"})

    with_rule(ctx, %{"operators" => [domain]}, fn _rule ->
      response = Fixtures.query(ctx, grant.token, %{"query" => "conformance"})

      Assert.check!(
        response.status in [401, 403],
        "a request the rule covers answered #{response.status}, expected not authorized"
      )
    end)
  end

  defp blocks_issuance(ctx) do
    {domain, operator} = operator(ctx)

    with_rule(ctx, %{"operators" => [domain], "categories" => [ctx.primary_category]}, fn _rule ->
      case Context.issue_grant(ctx, actions: ["read"], operator: operator) do
        {:error, _refused} ->
          :ok

        {:ok, _grant} ->
          Assert.fail!("a grant was issued to an operator a standing rule denies the category")
      end
    end)
  end

  defp others_unaffected(ctx) do
    {domain, _operator} = operator(ctx)
    grant = Context.issue_grant!(ctx, actions: ["read"])

    with_rule(ctx, %{"operators" => [domain]}, fn _rule ->
      Fixtures.query!(ctx, grant.token, %{"query" => "conformance"})
    end)
  end

  defp directive(ctx),
    do: %{
      "action" => "share",
      "effect" => "deny",
      "text" => "Never pass this on (#{ctx.nonce})",
      "categories" => [ctx.primary_category]
    }

  defp set_directive(ctx) do
    directive = post!(ctx, :directives, directive(ctx))
    id = directive["directiveId"]
    Assert.check!(is_binary(id), "the directive carries no directiveId")

    try do
      Assert.check!(Fixtures.date_time?(directive["createdAt"]), "createdAt must be a date-time")

      Assert.check!(
        Map.take(directive, ~w(action effect text)) ==
          Map.take(directive(ctx), ~w(action effect text)),
        "the directive does not carry what was set"
      )

      Assert.check!(
        Enum.any?(listed(ctx, :directives), &(&1["directiveId"] == id)),
        "GET /v2/directives does not list the directive"
      )
    after
      remove!(ctx, :directives, id)
    end
  end

  defp directive_audited(ctx) do
    id = post!(ctx, :directives, directive(ctx))["directiveId"]
    remove!(ctx, :directives, id)

    for type <- ["directive.set", "directive.removed"] do
      AuditLog.await!(
        ctx,
        type,
        &(AuditLog.event?(&1, type) and get_in(&1, ["data", "directiveId"]) == id)
      )
    end
  end

  defp delivered(ctx) do
    word = Context.unique_word(ctx)
    Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)
    id = post!(ctx, :directives, directive(ctx))["directiveId"]

    try do
      result = Fixtures.query!(ctx, Context.agent!(ctx).token, %{"query" => word})
      ids = for %{"directiveId" => id} <- List.wrap(result["directives"]), do: id

      Assert.check!(
        id in ids,
        "the result's directives do not include the directive set for the category disclosed"
      )

      match = fn event ->
        AuditLog.event?(event, "context.read") and
          get_in(event, ["participants", "retrievalId"]) == result["retrievalId"] and
          id in List.wrap(get_in(event, ["data", "directives"]))
      end

      AuditLog.await!(ctx, "context.read recording the directive the result carried", match,
        read?: true
      )
    after
      remove!(ctx, :directives, id)
    end
  end
end
