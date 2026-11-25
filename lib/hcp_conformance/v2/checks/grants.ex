defmodule HcpConformance.V2.Checks.Grants do
  @moduledoc """
  The grant (§6.1) and revocation (§6.2): the grant object the Authorizing
  Principal inspects, with its access details and approved purposes; what each
  caller may see of it; temporary-grant bounds, immediate revocation, a client
  relinquishing its own grant, lazy expiry, and narrowed grants (§6.1.5.1).
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.{Fixtures, Target}

  def group, do: "grants"

  def checks do
    person = [requires: [:rest, :person]]
    agent = [requires: [:rest, :agent]]
    hook = [requires: [:rest, :person, :hook]]

    [
      Check.new(
        "grants.management_list",
        "6.1.5",
        :must,
        "GET /v2/grants returns the person's grants as conforming grant objects, each detail with a purpose",
        &management_list/1,
        person
      ),
      Check.new(
        "grants.default_active",
        "9.4.6",
        :must,
        "Without a status filter the Management Client's list holds active grants only",
        &default_active/1,
        person
      ),
      Check.new(
        "grants.scopes_derived",
        "6.1.5",
        :must,
        "scopes grant nothing that access does not",
        &scopes_derived/1,
        person
      ),
      Check.new(
        "grants.client_sees_own",
        "5.2.6",
        :must,
        "A Context Client's GET /v2/grants returns only the grant its token was issued under",
        &client_sees_own/1,
        agent
      ),
      Check.new(
        "grants.not_disclosed",
        "6.1.5",
        :must,
        "A grant issued to one client is never disclosed to another",
        &not_disclosed/1,
        hook
      ),
      Check.new(
        "grants.temporary_bounds",
        "6.1.4",
        :must,
        "A temporary grant carries an expiresAt no more than 24 hours after issuedAt",
        &temporary_bounds/1,
        hook
      ),
      Check.new(
        "grants.issued_audited",
        "8.2",
        :must,
        "Issuing a grant appends grant.issued recording its access, type, expiry and modality",
        &issued_audited/1,
        hook
      ),
      Check.new(
        "grants.revocation",
        "6.2.2",
        :must,
        "Revocation by the person takes effect on the client's very next request",
        &revocation/1,
        hook
      ),
      Check.new(
        "grants.revocation_audited",
        "8.1",
        :must,
        "Revocation appends grant.revoked and the grant reads as revoked",
        &revocation_audited/1,
        hook
      ),
      Check.new(
        "grants.revoke_other_refused",
        "5.2.7",
        :must,
        "A Context Client naming any grant but its own in DELETE /v2/grants/{grantId} gets 403 scope-denied",
        &revoke_other_refused/1,
        hook
      ),
      Check.new(
        "grants.relinquish",
        "5.2.7",
        :must,
        "A Context Client relinquishes its own grant: 204, effective at once, recorded as grant.revoked naming the client",
        &relinquish/1,
        hook
      ),
      Check.new(
        "grants.expiry",
        "6.1.4",
        :must,
        "A lapsed temporary grant stops working and grant.expired is appended on first access",
        &expiry/1,
        hook
      ),
      Check.new(
        "grants.read_only",
        "6.1.1",
        :must,
        "A read-only grant cannot revise or withdraw entries",
        &read_only/1,
        hook
      ),
      Check.new(
        "grants.narrowed",
        "6.1.5.1",
        :must,
        "A narrowed grant carries its narrowedTo, every read excludes entries outside it, and the client sees refs, not ids",
        &narrowed/1,
        hook
      ),
      Check.new(
        "grants.unknown_narrowing",
        "6.1.5.1",
        :must,
        "A narrowing key the Authorization Service does not support is rejected at issuance",
        &unknown_narrowing/1,
        hook
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)

  defp list!(ctx, token, params \\ []) do
    response = Context.request(ctx, :get, Context.url(ctx, :grants), token: token, params: params)
    Assert.status!(response, 200, "GET /v2/grants")
    Target.grants(Assert.json_object!(response, "GET /v2/grants"))
  end

  defp find!(ctx, grant_id, params \\ []) do
    Enum.find(list!(ctx, person(ctx), params), &(&1["grantId"] == grant_id)) ||
      Assert.fail!("the person's grant list does not hold the grant #{grant_id}")
  end

  defp management_list(ctx) do
    if Context.has?(ctx, :hook), do: Context.issue_grant!(ctx, actions: ["read"])
    grants = list!(ctx, person(ctx))
    if grants == [], do: Assert.skip!("the subject has no active grants to inspect")
    problems = grants |> Enum.flat_map(&grant_problems/1) |> Enum.uniq()
    Assert.check!(problems == [], Enum.join(Enum.take(problems, 6), "; "))
  end

  @doc "What is wrong with a grant object (§6.1.5), as a list of messages."
  @spec grant_problems(map()) :: [String.t()]
  def grant_problems(grant) do
    client = grant["client"] || %{}
    temporary? = grant["grantType"] == "temporary"

    for {false, message} <- [
          {is_binary(grant["grantId"]), "grantId is required"},
          {is_binary(get_in(grant, ["subject", "id"])), "subject.id is required (invariant 3)"},
          {is_binary(get_in(grant, ["authorizingPrincipal", "id"])),
           "authorizingPrincipal.id is required (invariant 3)"},
          {is_binary(client["id"]) and is_binary(client["name"]) and client["name"] != "",
           "client.id and a client.name the person can recognize are required"},
          {is_binary(get_in(client, ["operator", "id"])) and
             is_binary(get_in(client, ["operator", "name"])),
           "client.operator must carry an id and a name (invariant 3)"},
          {is_list(grant["access"]) and grant["access"] != [] and
             Enum.all?(grant["access"], &detail?/1),
           "access must hold details, each with actions, categories and at least one purpose with a code and a description"},
          {is_list(grant["scopes"]), "scopes is required"},
          {grant["grantType"] in ["temporary", "persistent"],
           "grantType must be temporary or persistent"},
          {Fixtures.date_time?(grant["issuedAt"]), "issuedAt must be a date-time"},
          {if(temporary?,
             do: Fixtures.date_time?(grant["expiresAt"]),
             else: is_nil(grant["expiresAt"])
           ),
           "expiresAt must be a date-time for a temporary grant and null for a persistent one"},
          {grant["status"] in ["active", "revoked", "expired"],
           "status must be active, revoked or expired"}
        ],
        do: "grant #{inspect(grant["grantId"])}: #{message}"
  end

  defp detail?(%{"actions" => actions, "categories" => categories, "purposes" => purposes})
       when is_list(actions) and is_list(categories) and is_list(purposes) do
    actions != [] and Enum.all?(actions, &(&1 in ~w(read write provenance))) and categories != [] and
      purposes != [] and
      Enum.all?(
        purposes,
        &(is_map(&1) and is_binary(&1["code"]) and is_binary(&1["description"]))
      )
  end

  defp detail?(_detail), do: false

  defp default_active(ctx) do
    statuses = ctx |> list!(person(ctx)) |> Enum.map(& &1["status"]) |> Enum.uniq()

    Assert.check!(
      statuses -- ["active"] == [],
      "the default list holds grants with status #{inspect(statuses -- ["active"])}"
    )
  end

  defp scopes_derived(ctx) do
    if Context.has?(ctx, :hook), do: Context.issue_grant!(ctx, actions: ["read"])

    overstated =
      for grant <- list!(ctx, person(ctx)),
          is_list(grant["scopes"]),
          is_list(grant["access"]),
          extra = grant["scopes"] -- Target.scopes(Enum.filter(grant["access"], &detail?/1)),
          extra != [] do
        "grant #{grant["grantId"]}: #{Enum.join(extra, " ")}"
      end

    Assert.check!(
      overstated == [],
      "scopes that no access detail covers: " <> Enum.join(overstated, "; ")
    )
  end

  defp client_sees_own(ctx) do
    agent = Context.agent!(ctx)
    ids = ctx |> list!(agent.token) |> Enum.map(& &1["grantId"])

    Assert.check!(
      ids == [agent.grant_id],
      "the client received the grants #{inspect(ids)}, expected only its own"
    )
  end

  defp not_disclosed(ctx) do
    first = Context.issue_grant!(ctx, actions: ["read"])
    second = Context.issue_grant!(ctx, actions: ["read"])
    seen = ctx |> list!(first.token) |> Jason.encode!()

    Assert.check!(
      not String.contains?(seen, second.grant_id),
      "a client's grant list names another client's grant"
    )

    Assert.check!(
      not String.contains?(seen, second.client_id),
      "a client's grant list names another client"
    )
  end

  defp temporary_bounds(ctx) do
    issued = Context.issue_grant!(ctx, actions: ["read"], expires_in: 86_400)
    grant = find!(ctx, issued.grant_id)

    Assert.check!(
      grant["grantType"] == "temporary",
      "the grant's type is #{inspect(grant["grantType"])}, expected temporary"
    )

    with {:ok, from, _} <- DateTime.from_iso8601(to_string(grant["issuedAt"])),
         {:ok, to, _} <- DateTime.from_iso8601(to_string(grant["expiresAt"])) do
      seconds = DateTime.diff(to, from)

      Assert.check!(
        seconds > 0 and seconds <= 86_400,
        "expiresAt is #{seconds} s after issuedAt; the maximum is 86 400"
      )
    else
      _invalid -> Assert.fail!("a temporary grant needs issuedAt and expiresAt as date-times")
    end
  end

  defp issued_audited(ctx) do
    issued = Context.issue_grant!(ctx, actions: ["read"])

    [event | _] =
      AuditLog.await!(
        ctx,
        "grant.issued",
        &AuditLog.event?(&1, "grant.issued", grantId: issued.grant_id)
      )

    data = event["data"] || %{}
    missing = Enum.reject(~w(access grantType expiresAt modality), &Map.has_key?(data, &1))
    Assert.check!(missing == [], "grant.issued data lacks " <> Enum.join(missing, ", "))

    Assert.check!(
      data["expiresAt"] == issued.expires_at or is_nil(issued.expires_at),
      "grant.issued does not record the grant's expiry"
    )
  end

  defp revoke!(ctx, token, grant_id) do
    response = Context.request(ctx, :delete, Context.grant_url(ctx, grant_id), token: token)
    Assert.status!(response, 204, "DELETE /v2/grants/{grantId}")
  end

  defp refused_now!(ctx, token, what) do
    response = Fixtures.query(ctx, token, %{"query" => "conformance"})

    Assert.check!(
      response.status in [401, 403],
      "#{what}: a request under the grant answered #{response.status}, expected 401 or 403"
    )
  end

  defp revocation(ctx) do
    grant = Context.issue_grant!(ctx, actions: ["read"])
    Fixtures.query!(ctx, grant.token, %{"query" => "conformance"})
    revoke!(ctx, person(ctx), grant.grant_id)
    refused_now!(ctx, grant.token, "after revocation")
  end

  defp revocation_audited(ctx) do
    grant = Context.issue_grant!(ctx, actions: ["read"])
    revoke!(ctx, person(ctx), grant.grant_id)

    AuditLog.await!(
      ctx,
      "grant.revoked",
      &AuditLog.event?(&1, "grant.revoked", grantId: grant.grant_id)
    )

    status = find!(ctx, grant.grant_id, status: "revoked")["status"]
    Assert.check!(status == "revoked", "the revoked grant reads as #{inspect(status)}")
  end

  defp revoke_other_refused(ctx) do
    mine = Context.issue_grant!(ctx, actions: ["read"])
    other = Context.issue_grant!(ctx, actions: ["read"])

    response =
      Context.request(ctx, :delete, Context.grant_url(ctx, other.grant_id), token: mine.token)

    Assert.problem!(
      response,
      403,
      "scope-denied",
      "a Context Client revoking another client's grant"
    )

    Fixtures.query!(ctx, other.token, %{"query" => "conformance"})
  end

  defp relinquish(ctx) do
    grant = Context.issue_grant!(ctx, actions: ["read"])
    revoke!(ctx, grant.token, grant.grant_id)
    refused_now!(ctx, grant.token, "after relinquishing")

    [event | _] =
      AuditLog.await!(
        ctx,
        "grant.revoked",
        &AuditLog.event?(&1, "grant.revoked", grantId: grant.grant_id)
      )

    role = get_in(event, ["participants", "initiator", "role"])

    Assert.check!(
      role == "context-client",
      "grant.revoked names #{inspect(role)} as initiator, expected the relinquishing context-client"
    )
  end

  defp expiry(ctx) do
    grant = Context.issue_grant!(ctx, actions: ["read"], expires_in: 2)
    Process.sleep(3_000)
    refused_now!(ctx, grant.token, "after expiry")

    AuditLog.await!(
      ctx,
      "grant.expired",
      &AuditLog.event?(&1, "grant.expired", grantId: grant.grant_id)
    )
  end

  defp read_only(ctx) do
    word = Context.unique_word(ctx)
    Fixtures.create!(ctx, person(ctx), value: "I prefer " <> word)
    grant = Context.issue_grant!(ctx, actions: ["read"])
    [disclosure] = Fixtures.found(ctx, grant.token, word)
    revision = Fixtures.revise(ctx, grant.token, disclosure["ref"], %{"expectedVersion" => 1})
    Assert.problem!(revision, 403, "scope-denied", "a revision by a read-only client")

    Assert.problem!(
      Fixtures.delete(ctx, grant.token, disclosure["ref"]),
      403,
      "scope-denied",
      "a withdrawal by a read-only client"
    )
  end

  defp narrowed(ctx) do
    word = Context.unique_word(ctx)
    inside = Fixtures.create!(ctx, person(ctx), value: "Inside #{word}")
    Fixtures.create!(ctx, person(ctx), value: "Outside #{word}")
    narrowing = %{"entryIds" => [inside["id"]]}

    grant =
      case Context.issue_grant(ctx, actions: ["read"], narrowed_to: narrowing) do
        {:ok, grant} ->
          grant

        {:error, message} ->
          Assert.skip!("the implementation does not narrow grants by entryIds: " <> message)
      end

    [detail | _] = find!(ctx, grant.grant_id)["access"]

    Assert.check!(
      detail["narrowedTo"] == narrowing,
      "the grant object does not carry its narrowedTo (rule 3)"
    )

    values =
      ctx
      |> Fixtures.query!(grant.token, %{"query" => word, "maxEntries" => 20})
      |> Fixtures.values()

    Assert.check!(
      values == ["Inside #{word}"],
      "a narrowed grant's query returned #{inspect(values)} (rule 4)"
    )

    own = ctx |> list!(grant.token) |> Jason.encode!()

    Assert.check!(
      not String.contains?(own, inside["id"]),
      "the client's own grant names a narrowed entry by its id, not its ref"
    )
  end

  defp unknown_narrowing(ctx) do
    narrowing = %{"https://conformance.hcp.example/narrowing/unsupported" => ["x"]}

    case Context.issue_grant(ctx, actions: ["read"], narrowed_to: narrowing) do
      {:error, _refused} ->
        :ok

      {:ok, _grant} ->
        Assert.fail!(
          "a grant narrowed by a key no implementation supports was issued; unknown narrowing must fail closed"
        )
    end
  end
end
