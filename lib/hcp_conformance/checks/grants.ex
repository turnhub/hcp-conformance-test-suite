defmodule HcpConformance.Checks.Grants do
  @moduledoc """
  The grant model (§4.1) and revocation (§4.2): the grant object a person
  inspects, per-client disclosure, temporary-grant bounds, immediate revocation,
  lazy expiry, write scope, and narrowed grants (§4.1.5.1).

  Most checks need grants created on demand, so they run only with the
  conformance hook.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, Envelope, Fixtures}

  @grant_types ["temporary", "persistent"]
  @statuses ["active", "revoked", "expired"]
  @max_temporary_seconds 24 * 3600

  def group, do: "grants"

  def checks do
    hook = [requires: [:rest, :person, :hook]]

    [
      Check.new(
        "grants.person_list",
        "4.1.5",
        :must,
        "GET /v1/grants returns the person's grants as conforming grant objects",
        &person_list/1,
        requires: [:rest, :person]
      ),
      Check.new(
        "grants.default_active",
        "4.1.5",
        :must,
        "Without a status filter the person's list holds active grants only",
        &default_active/1,
        requires: [:rest, :person]
      ),
      Check.new(
        "grants.client_sees_own",
        "4.1.5",
        :must,
        "A client's GET /v1/grants returns only the grant its token was issued under",
        &client_sees_own/1,
        requires: [:rest, :agent]
      ),
      Check.new(
        "grants.not_disclosed",
        "4.1.5",
        :must,
        "A grant issued to one client is never disclosed to another",
        &not_disclosed/1,
        hook
      ),
      Check.new(
        "grants.temporary_bounds",
        "4.1.4",
        :must,
        "A temporary grant carries an expiresAt no more than 24 hours after issuedAt",
        &temporary_bounds/1,
        hook
      ),
      Check.new(
        "grants.issued_audited",
        "4.1.4",
        :must,
        "Issuing a grant appends grant.issued recording its expiry",
        &issued_audited/1,
        hook
      ),
      Check.new(
        "grants.revocation",
        "4.2.2",
        :must,
        "Revocation by the person takes effect on the client's very next request",
        &revocation/1,
        hook
      ),
      Check.new(
        "grants.revocation_audited",
        "4.3.1",
        :must,
        "Revocation appends grant.revoked and the grant reads as revoked",
        &revocation_audited/1,
        hook
      ),
      Check.new(
        "grants.revoke_person_only",
        "3.3",
        :must,
        "A client cannot revoke grants: DELETE /v1/grants/{id} is the person's alone",
        &revoke_person_only/1,
        requires: [:rest, :agent]
      ),
      Check.new(
        "grants.expiry",
        "4.1.4",
        :must,
        "A lapsed temporary grant stops working and grant.expired is appended on first access",
        &expiry/1,
        hook
      ),
      Check.new(
        "grants.read_only",
        "4.1.1",
        :must,
        "A read-only grant cannot update or delete entries",
        &read_only/1,
        hook
      ),
      Check.new(
        "grants.restrictions",
        "4.1.5.1",
        :must,
        "A narrowed grant carries its restrictions and every read excludes entries outside them",
        &restrictions/1,
        hook
      )
    ]
  end

  @doc "Violations of the §4.1.5 grant object shape."
  @spec grant_violations(term()) :: [String.t()]
  def grant_violations(grant) when is_map(grant) do
    scopes = grant["scopes"]
    restrictions = grant["restrictions"]
    type = grant["grantType"]

    [
      {is_binary(grant["grantId"]), "grantId must be a string"},
      {is_map(grant["client"]) and is_binary(grant["client"]["id"]),
       "client.id must be a string"},
      {is_map(grant["client"]) and is_binary(grant["client"]["name"]) and
         grant["client"]["name"] != "", "client.name must be a name the person can recognize"},
      {is_list(scopes) and scopes != [] and Enum.all?(scopes, &scope?/1),
       "scopes must be hcp:{category}:{read|write} strings, no wildcards"},
      {type in @grant_types, "grantType must be temporary or persistent"},
      {Envelope.iso8601?(grant["issuedAt"]), "issuedAt must be ISO-8601"},
      {type != "temporary" or Envelope.iso8601?(grant["expiresAt"]),
       "a temporary grant must carry a non-null expiresAt"},
      {type != "persistent" or is_nil(grant["expiresAt"]),
       "a persistent grant must carry a null expiresAt"},
      {grant["status"] in @statuses, "status must be active, revoked or expired"},
      {is_nil(restrictions) or
         (is_list(restrictions) and
            Enum.all?(restrictions, &(is_map(&1) and &1["scope"] in List.wrap(scopes)))),
       "every restriction must reference a scope the grant holds"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&"grant #{inspect(grant["grantId"])}: #{elem(&1, 1)}")
  end

  def grant_violations(_grant), do: ["a grant must be a JSON object"]

  defp scope?(scope), do: is_binary(scope) and Regex.match?(~r/^hcp:[^*\s]+:(read|write)$/, scope)

  defp list!(ctx, token, params \\ []) do
    response = Context.request(ctx, :get, Context.url(ctx, :grants), token: token, params: params)
    Assert.status!(response, 200, "GET /v1/grants")
    body = Assert.json_object!(response, "GET /v1/grants")
    Assert.check!(is_list(body["grants"]), "the body must carry a grants array")
    body["grants"]
  end

  defp person_list(ctx) do
    grants = list!(ctx, Context.person!(ctx))
    violations = Enum.flat_map(grants, &grant_violations/1)
    Assert.check!(violations == [], Enum.join(violations, "; "))
  end

  defp default_active(ctx) do
    statuses = ctx |> list!(Context.person!(ctx)) |> Enum.map(& &1["status"]) |> Enum.uniq()

    Assert.check!(
      statuses -- ["active"] == [],
      "the default list holds grants with status #{inspect(statuses -- ["active"])}"
    )
  end

  defp client_sees_own(ctx) do
    agent = Context.agent!(ctx)
    grants = list!(ctx, agent.token)

    Assert.check!(
      length(grants) == 1,
      "a client must see exactly its own grant, got #{length(grants)}"
    )

    if agent.grant_id do
      Assert.check!(
        hd(grants)["grantId"] == agent.grant_id,
        "the client was shown a grant other than its own"
      )
    end
  end

  defp not_disclosed(ctx) do
    first = Context.issue_grant!(ctx, scopes: Context.scopes(ctx.primary_category, ["read"]))
    second = Context.issue_grant!(ctx, scopes: Context.scopes(ctx.primary_category, ["read"]))
    seen = ctx |> list!(first.token) |> Enum.map(& &1["grantId"])

    Assert.check!(
      second.grant_id not in seen,
      "one client's grant list disclosed another client's grant"
    )
  end

  defp find_grant!(ctx, grant_id, params \\ []) do
    ctx
    |> list!(Context.person!(ctx), params)
    |> Enum.find(&(&1["grantId"] == grant_id))
    |> case do
      nil ->
        Assert.fail!(
          "grant #{grant_id} is missing from the person's grant list#{if params != [], do: " (#{inspect(params)})"}"
        )

      grant ->
        grant
    end
  end

  defp temporary_bounds(ctx) do
    issued =
      Context.issue_grant!(ctx,
        scopes: Context.scopes(ctx.primary_category, ["read"]),
        expires_in: 3600
      )

    grant = find_grant!(ctx, issued.grant_id)

    Assert.check!(
      grant["grantType"] == "temporary",
      "the grant was issued as temporary but reads as #{inspect(grant["grantType"])}"
    )

    with {:ok, issued_at, _} <- DateTime.from_iso8601(grant["issuedAt"] || ""),
         {:ok, expires_at, _} <- DateTime.from_iso8601(grant["expiresAt"] || "") do
      lifetime = DateTime.diff(expires_at, issued_at)

      Assert.check!(
        lifetime > 0 and lifetime <= @max_temporary_seconds,
        "the grant lives #{lifetime} s; a temporary grant may live at most 24 h"
      )
    else
      _error -> Assert.fail!("issuedAt and expiresAt must be ISO-8601 timestamps")
    end
  end

  defp issued_audited(ctx) do
    issued = Context.issue_grant!(ctx, scopes: Context.scopes(ctx.primary_category, ["read"]))
    grant = find_grant!(ctx, issued.grant_id)

    [event | _] =
      AuditLog.await!(
        ctx,
        "grant.issued",
        &AuditLog.event?(&1, "grant.issued", grantId: issued.grant_id)
      )

    minute = String.slice(grant["expiresAt"] || "", 0, 16)

    Assert.check!(
      is_binary(event["detail"]) and minute != "" and String.contains?(event["detail"], minute),
      "the grant.issued event must record the expiry (#{grant["expiresAt"]}), detail was #{inspect(event["detail"])}"
    )
  end

  defp works?(ctx, token) do
    response =
      Context.request(ctx, :post, Context.url(ctx, :search),
        token: token,
        json: %{
          "query" => "conformance",
          "categories" => [ctx.primary_category],
          "purpose" => "HCP conformance check"
        }
      )

    response.status == 200
  end

  defp revoke!(ctx, grant_id) do
    Context.request(ctx, :delete, Context.grant_url(ctx, grant_id), token: Context.person!(ctx))
    |> Assert.status!(200, "DELETE /v1/grants/{id} by the person")
  end

  defp revocation(ctx) do
    grant = Context.issue_grant!(ctx, scopes: Context.scopes(ctx.primary_category, ["read"]))
    Assert.check!(works?(ctx, grant.token), "the new grant did not work before revocation")
    revoke!(ctx, grant.grant_id)

    response =
      Context.request(ctx, :post, Context.url(ctx, :search),
        token: grant.token,
        json: %{
          "query" => "conformance",
          "categories" => [ctx.primary_category],
          "purpose" => "HCP conformance check"
        }
      )

    Assert.status!(response, [401, 403], "the client's request after revocation")
  end

  defp revocation_audited(ctx) do
    grant = Context.issue_grant!(ctx, scopes: Context.scopes(ctx.primary_category, ["read"]))
    revoke!(ctx, grant.grant_id)

    AuditLog.await!(
      ctx,
      "grant.revoked",
      &AuditLog.event?(&1, "grant.revoked", grantId: grant.grant_id)
    )

    revoked = find_grant!(ctx, grant.grant_id, status: "revoked")

    Assert.check!(
      revoked["status"] == "revoked",
      "the revoked grant reads as #{inspect(revoked["status"])}"
    )
  end

  defp revoke_person_only(ctx) do
    agent = Context.agent!(ctx)
    grant_id = agent.grant_id || Assert.skip!("the agent's grant id is unknown")
    response = Context.request(ctx, :delete, Context.grant_url(ctx, grant_id), token: agent.token)
    Assert.refused!(response, "a client revoking a grant")
  end

  defp expiry(ctx) do
    grant =
      Context.issue_grant!(ctx,
        scopes: Context.scopes(ctx.primary_category, ["read"]),
        expires_in: 2
      )

    Process.sleep(3_500)

    response =
      Context.request(ctx, :post, Context.url(ctx, :search),
        token: grant.token,
        json: %{
          "query" => "conformance",
          "categories" => [ctx.primary_category],
          "purpose" => "HCP conformance check"
        }
      )

    Assert.status!(response, [401, 403], "a request under a lapsed temporary grant")

    AuditLog.await!(
      ctx,
      "grant.expired",
      &AuditLog.event?(&1, "grant.expired", grantId: grant.grant_id)
    )
  end

  defp read_only(ctx) do
    entry = Fixtures.create!(ctx, Context.person!(ctx))
    grant = Context.issue_grant!(ctx, scopes: Context.scopes(ctx.primary_category, ["read"]))

    Context.request(ctx, :put, Context.entry_url(ctx, entry["id"]),
      token: grant.token,
      json: %{"updatedPreference" => "Not allowed", "reason" => "HCP conformance check"}
    )
    |> Assert.problem!(403, "scope-denied", "a read-only client updating an entry")

    Context.request(ctx, :delete, Context.entry_url(ctx, entry["id"]), token: grant.token)
    |> Assert.problem!(403, "scope-denied", "a read-only client deleting an entry")
  end

  defp restrictions(ctx) do
    word = Context.unique_word(ctx)
    allowed = Fixtures.create!(ctx, Context.person!(ctx), preference: "Narrowed in #{word}")
    excluded = Fixtures.create!(ctx, Context.person!(ctx), preference: "Narrowed out #{word}")
    scope = "hcp:#{ctx.primary_category}:read"
    restriction = [%{"scope" => scope, "narrowedTo" => %{"entryIds" => [allowed["id"]]}}]

    grant =
      case Context.issue_grant(ctx, scopes: [scope], restrictions: restriction) do
        {:ok, grant} ->
          grant

        {:error, message} ->
          Assert.skip!("the conformance hook does not issue narrowed grants: " <> message)
      end

    [object] = list!(ctx, grant.token)

    Assert.check!(
      is_list(object["restrictions"]) and object["restrictions"] != [],
      "the narrowed grant's object does not carry its restrictions (Rule 3)"
    )

    body = Fixtures.search!(ctx, grant.token, %{"query" => word, "maxEntries" => 10})
    returned = Fixtures.ids(body)

    Assert.check!(
      excluded["id"] not in returned,
      "the search returned an entry outside the grant's restrictions (Rule 4)"
    )

    Assert.check!(
      allowed["id"] in returned,
      "the search did not return the entry the grant is narrowed to"
    )

    Fixtures.get(ctx, grant.token, excluded["id"])
    |> Assert.problem!(403, "scope-denied", "reading an entry outside the grant's restrictions")
  end
end
