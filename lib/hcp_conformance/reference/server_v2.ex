defmodule HcpConformance.Reference.ServerV2 do
  @moduledoc """
  A small, in-memory HCP v2 (2.0-draft-3) implementation of the HTTP Binding and
  the MCP Binding, with the conformance hook (docs/HOOK.md).

  It plays the part for v2 that `HcpConformance.Reference.Server` plays for v1:
  the suite's tests run every v2 check against it, as written and with
  deliberate faults, and a hosted suite can mount it.

  It claims the First-Party package with both bindings: Core, the HTTP Binding,
  the MCP Binding over Streamable HTTP (`HcpConformance.Reference.McpV2`), the
  General Context Profile and the First-Party Authorization Profile. It does not
  claim the Memory Manager Profile, so it refuses `model-inferred` entries, nor
  the VC Evidence Profile, so it refuses credentials as content. Not
  implemented, and not yet checked by the suite: import, the disclosure summary,
  relationships between entries, revocation notifications, and the `notTo` a
  standing rule adds to an onward-sharing election.

  The person's token is the Management Client acting for the Authorizing
  Principal; a grant's token is a Context Client. Options are those of the v1
  reference server, and `bindings` (both by default): `["mcp"]` makes it the
  MCP-only provider the First-Party package permits, with no HTTP Binding and
  so no governance plane to reach.
  """

  @behaviour Plug

  import Plug.Conn

  alias HcpConformance.Reference.{McpV2, ModelV2, Store}

  @version "2.0"
  @problem_base "https://hcp.example/problems/"
  @context ["https://hcp.example/contexts/v2"]
  @conforms_to ~w(https://hcp.example/spec/core/2.0
                  https://hcp.example/spec/bindings/http/2.0
                  https://hcp.example/spec/bindings/mcp/2.0
                  https://hcp.example/spec/profiles/general-context/2.0
                  https://hcp.example/spec/profiles/first-party-authorization/2.0)
  @problems %{
    "invalid-token" => {401, "Missing or invalid authorization"},
    "scope-denied" => {403, "Outside the caller's grant"},
    "malformed-request" => {422, "Request fails validation"},
    "idempotency-conflict" => {409, "Idempotency key reused with a differing body"},
    "version-conflict" => {409, "Not the entry's current version"},
    "rate-limited" => {429, "Rate limit exceeded"},
    "unsupported-version" => {400, "Requested protocol version not supported"}
  }

  # Deliberate defects, one per behaviour a check guards.
  @faults ~w(omit_version_header ignore_version_header trust_provenance accept_inferred leak_id
             ref_shared long_use_until not_found_for_client no_purpose_check pad_results no_ceiling
             count_leak no_idempotency stale_confirmation hard_delete_keeps revocation_ignored
             governance_open rule_ignored no_directives plain_cursor share_unrecorded
             mcp_missing_tool mcp_governance_tool mcp_text_only mcp_no_challenge
             mcp_existence_challenge mcp_token_echo)a

  @doc "The fault switches the server understands."
  @spec faults() :: [atom()]
  def faults, do: @faults

  @impl Plug
  def init(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      hook_secret: Keyword.get(opts, :hook_secret, "reference-hook-secret"),
      base_url: Keyword.get(opts, :base_url),
      bindings: Keyword.get(opts, :bindings, ["http", "mcp"]),
      faults: MapSet.new(Keyword.get(opts, :faults, []))
    }
  end

  @impl Plug
  def call(conn, opts) do
    {raw, conn} = read_all(conn, "")
    conn = fetch_query_params(conn)

    request = %{
      method: conn.method,
      path: Enum.map(conn.path_info, &URI.decode/1),
      query: conn.query_params,
      headers: Map.new(conn.req_headers),
      raw: raw,
      json: decode(raw),
      base: opts.base_url || base_url(conn),
      now: DateTime.utc_now() |> DateTime.truncate(:second),
      faults: opts.faults,
      bindings: opts.bindings,
      hook_secret: opts.hook_secret
    }

    {status, body, type, headers} = route(request, opts.store)

    # §9.3: every response carries HCP-Version, bodiless and error responses too.
    headers =
      if fault?(request, :omit_version_header),
        do: headers,
        else: [{"hcp-version", @version} | headers]

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)

    case body do
      nil -> send_resp(conn, status, "")
      body -> conn |> put_resp_content_type(type, nil) |> send_resp(status, Jason.encode!(body))
    end
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {acc <> chunk, conn}
      {:more, chunk, conn} -> read_all(conn, acc <> chunk)
    end
  end

  defp decode(""), do: nil

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, value} -> value
      {:error, _reason} -> :invalid
    end
  end

  defp base_url(conn) do
    scheme = get_req_header(conn, "x-forwarded-proto") |> List.first() || to_string(conn.scheme)

    default_port? =
      (scheme == "https" and conn.port in [443, 80]) or (scheme == "http" and conn.port == 80)

    host = if default_port?, do: conn.host, else: "#{conn.host}:#{conn.port}"
    mount = Enum.map_join(conn.script_name, "", &("/" <> &1))
    "#{scheme}://#{host}#{mount}"
  end

  # Responses -------------------------------------------------------------------

  defp ok(status, body), do: {status, body, "application/ld+json", []}
  defp no_content, do: {204, nil, nil, []}

  defp problem(slug, detail) do
    {status, title} = Map.fetch!(@problems, slug)

    body = %{
      "type" => @problem_base <> slug,
      "title" => title,
      "status" => status,
      "detail" => detail
    }

    headers = if slug == "rate-limited", do: [{"retry-after", "1"}], else: []
    {status, body, "application/problem+json", headers}
  end

  defp not_found(detail) do
    body = %{"type" => "about:blank", "title" => "Not found", "status" => 404, "detail" => detail}
    {404, body, "application/problem+json", []}
  end

  # §5.5: not authorized never says whether the entry exists.
  defp denied(request) do
    if fault?(request, :not_found_for_client),
      do: not_found("No such entry"),
      else: problem("scope-denied", "The request falls outside the caller's grant")
  end

  defp fault?(request, fault), do: MapSet.member?(request.faults, fault)

  # Routing ---------------------------------------------------------------------

  defp route(%{path: ["conformance-hook" | rest]} = request, store),
    do: hook(request, rest, store)

  defp route(request, store) do
    version = request.headers["hcp-version"]

    if version not in [nil, @version] and not fault?(request, :ignore_version_header) do
      problem("unsupported-version", "This implementation speaks HCP #{@version}")
    else
      dispatch(request, store)
    end
  end

  defp dispatch(%{method: "GET", path: [".well-known", "hcp-configuration"]} = request, _store),
    do: discovery(request)

  # RFC 9728: where MCP's authorization looks for the resource's metadata. A
  # First-Party provider has no OAuth authorization server to name in it.
  defp dispatch(%{method: "GET", path: [".well-known", "oauth-protected-resource"]} = request, _),
    do:
      {200, %{"resource" => request.base, "bearer_methods_supported" => ["header"]},
       "application/json", []}

  defp dispatch(%{method: "POST", path: ["mcp"]} = request, store),
    do: if("mcp" in request.bindings, do: mcp(request, store), else: not_found("No such route"))

  defp dispatch(%{path: ["v2" | path]} = request, store) do
    case "http" in request.bindings && handler(request.method, path) do
      handler when is_function(handler) -> authed(request, store, handler)
      _none -> not_found("No such route")
    end
  end

  defp dispatch(_request, _store), do: not_found("No such route")

  defp handler("POST", ["entries", "query"]), do: &query/3
  defp handler("POST", ["entries"]), do: &create/3
  defp handler("GET", ["entries", id]), do: &get_entry(&1, &2, &3, id)
  defp handler("POST", ["entries", id, "revisions"]), do: &revise(&1, &2, &3, id)
  defp handler("DELETE", ["entries", id]), do: &delete(&1, &2, &3, id)
  defp handler("POST", ["entries", id, "confirmation"]), do: governed(&confirm(&1, &2, &3, id))
  defp handler("PUT", ["entries", id, "categories"]), do: governed(&recategorize(&1, &2, &3, id))
  defp handler("PUT", ["entries", id, "purposes"]), do: governed(&restrict(&1, &2, &3, id))
  defp handler("POST", ["shares"]), do: &report_share/3
  defp handler("GET", ["grants"]), do: &list_grants/3
  defp handler("DELETE", ["grants", id]), do: &revoke(&1, &2, &3, id)
  defp handler("GET", ["audit"]), do: governed(&audit/3)
  defp handler("GET", ["export"]), do: governed(&export/3)

  defp handler("GET", [kind]) when kind in ["rules", "directives"],
    do: governed(&list(&1, &2, &3, kind))

  defp handler("POST", [kind]) when kind in ["rules", "directives"],
    do: governed(&set(&1, &2, &3, kind))

  defp handler("DELETE", [kind, id]) when kind in ["rules", "directives"],
    do: governed(&unset(&1, &2, &3, kind, id))

  defp handler(_method, _path), do: nil

  # §6.1.9: a governance operation is the Management Client's alone.
  defp governed(handler) do
    fn request, subject, actor ->
      if management?(actor) or fault?(request, :governance_open),
        do: handler.(request, subject, actor),
        else:
          {problem("scope-denied", "A governance operation is the Management Client's alone"),
           subject}
    end
  end

  defp discovery(request) do
    base = request.base
    bindings = request.bindings

    document = %{
      "hcp_version" => @version,
      "provider" => base,
      "provider_operator" => operator(request),
      "conformsTo" => claims(bindings),
      "bindings" => bindings,
      "jwks_uri" => base <> "/.well-known/jwks.json",
      "supported_categories" => ModelV2.described_categories(),
      "category_registry" => "1",
      "accepts_entry_schemas" => [ModelV2.entry_schema()],
      "minimization_method" => "lexical",
      "audit_durability" => %{"default" => "synchronous"},
      "audit_integrity" => "append-only",
      "storage_encryption" => "server",
      "rate_limits" => %{"documentation_url" => base <> "/.well-known/hcp-configuration"}
    }

    ok(
      200,
      document
      |> Map.merge(http_members(base, bindings))
      |> Map.merge(mcp_members(base, bindings))
    )
  end

  defp claims(bindings), do: Enum.filter(@conforms_to, &claimed?(&1, bindings))

  # A binding's identifier is claimed only where the binding is exposed (§19.3).
  defp claimed?(identifier, bindings) do
    case Regex.run(~r{/spec/bindings/(\w+)/}, identifier) do
      [_match, binding] -> binding in bindings
      nil -> true
    end
  end

  # The members required where the HTTP Binding is exposed (§19.3).
  defp http_members(base, bindings) do
    if "http" in bindings do
      %{
        "entries_endpoint" => base <> "/v2/entries",
        "grants_endpoint" => base <> "/v2/grants",
        "audit_endpoint" => base <> "/v2/audit",
        "export_endpoint" => base <> "/v2/export",
        "rules_endpoint" => base <> "/v2/rules",
        "directives_endpoint" => base <> "/v2/directives",
        "shares_endpoint" => base <> "/v2/shares",
        "pagination" => %{"audit" => "cursor"},
        "problem_type_base" => @problem_base
      }
    else
      %{}
    end
  end

  defp mcp_members(base, bindings) do
    if "mcp" in bindings,
      do: %{
        "mcp_endpoint" => base <> "/mcp",
        "protected_resource_metadata" => McpV2.metadata_url(base)
      },
      else: %{}
  end

  defp operator(request), do: %{"id" => request.base, "name" => "HCP reference implementation"}

  defp management_client(request) do
    %{
      "id" => request.base <> "/clients/management",
      "name" => "Reference management client",
      "operator" => operator(request)
    }
  end

  # The MCP Binding (§10): the context operations as tools -------------------------------

  defp mcp(request, store) do
    case McpV2.parse(request) do
      {:error, response} ->
        response

      {:ok, %{method: "server/discover"} = rpc} ->
        McpV2.result(rpc, McpV2.discover(request.base, claims(request.bindings)))

      {:ok, rpc} ->
        request |> authed(store, &mcp_call(&1, &2, &3, rpc)) |> unauthenticated(request)
    end
  end

  # §10.4: missing or invalid authorization is refused at the HTTP layer, with a challenge.
  defp unauthenticated({401, body, type, headers}, request),
    do: {401, body, type, [McpV2.unauthenticated(request.base) | headers]}

  defp unauthenticated(response, _request), do: response

  defp mcp_call(request, subject, _actor, %{method: "tools/list"} = rpc),
    do: {McpV2.result(rpc, %{"tools" => McpV2.tools(request.faults)}), subject}

  defp mcp_call(request, subject, actor, rpc) do
    case McpV2.operation(rpc.params, subject.did) do
      :unknown -> {McpV2.error(rpc, 200, -32_602, "Unknown tool"), subject}
      {:invalid, detail} -> {McpV2.tool_error(rpc, "malformed-request", detail), subject}
      {:ok, operation} -> call_tool(request, subject, actor, rpc, operation)
    end
  end

  # A tool call runs the operation the HTTP Binding would, under the same grant
  # (invariant 10). What the grant cannot cover whatever is stored is refused
  # first, as a challenge the host can act on.
  defp call_tool(request, subject, actor, rpc, operation) do
    case insufficient(request, actor, operation) do
      nil ->
        handler = handler(operation.method, operation.path)
        {outcome, subject} = handler.(Map.merge(request, operation), subject, actor)
        {tool_response(request, rpc, operation, outcome), subject}

      {scopes, description} ->
        {insufficient_scope(request, scopes, description), subject}
    end
  end

  defp insufficient_scope(request, scopes, description) do
    {status, body, type, headers} = problem("scope-denied", description)
    {status, body, type, [McpV2.challenge(request.base, scopes, description) | headers]}
  end

  defp tool_response(request, rpc, operation, {403, _, _, _} = outcome) do
    # The fault answers a denial that depends on what is stored with a
    # challenge, which tells the caller the entry exists.
    if fault?(request, :mcp_existence_challenge) and operation.method == "GET",
      do: insufficient_scope(request, ["hcp:unknown:read"], "The entry is outside the grant"),
      else: McpV2.tool_result(rpc, outcome, request.faults)
  end

  defp tool_response(request, rpc, _operation, outcome) do
    response = McpV2.tool_result(rpc, outcome, request.faults)
    if fault?(request, :mcp_token_echo), do: echo_token(response, request), else: response
  end

  defp echo_token({status, body, type, headers}, request) do
    leak = %{"type" => "text", "text" => "token: #{bearer(request)}"}
    {status, update_in(body, ["result", "content"], &(&1 ++ [leak])), type, headers}
  end

  # §10.4: the scopes a request needs that the grant lacks, with why, where the
  # denial follows from the request alone; nil where it does not, or cannot.
  defp insufficient(request, actor, operation) do
    if management?(actor) or fault?(request, :mcp_no_challenge),
      do: nil,
      else: lacking(actor.grant, operation)
  end

  defp lacking(grant, %{path: ["entries", "query"], json: body}) do
    purpose = body["purpose"]
    readable = ModelV2.categories_for(grant, "read")
    wanted = if is_list(body["categories"]), do: body["categories"], else: readable

    approved =
      if is_binary(purpose), do: ModelV2.readable_categories(grant, purpose), else: wanted

    cond do
      wanted -- readable != [] -> uncovered(wanted -- readable, "read")
      wanted == [] or wanted -- approved != [] -> unapproved(wanted, purpose)
      true -> nil
    end
  end

  defp lacking(grant, %{method: "GET", query: %{"purpose" => purpose}}) do
    if ModelV2.readable_categories(grant, purpose) == [],
      do: unapproved(ModelV2.categories_for(grant, "read"), purpose)
  end

  defp lacking(grant, %{method: "POST", path: ["entries"], json: body}) do
    categories = get_in(body, ["classification", "categories"])

    missing =
      if is_list(categories), do: categories -- ModelV2.categories_for(grant, "write"), else: []

    if missing != [] and Enum.all?(missing, &ModelV2.category?/1), do: uncovered(missing, "write")
  end

  defp lacking(_grant, _operation), do: nil

  defp uncovered(categories, action),
    do:
      {Enum.map(categories, &"hcp:#{&1}:#{action}"),
       "The grant does not cover #{action} on #{Enum.join(categories, ", ")}"}

  defp unapproved(categories, purpose),
    do:
      {Enum.map(categories, &"hcp:#{&1}:read"),
       "The grant does not approve the purpose #{purpose}"}

  # Authentication and authorization ---------------------------------------------------

  defp bearer(request) do
    case request.headers["authorization"] do
      "Bearer " <> token -> String.trim(token)
      "bearer " <> token -> String.trim(token)
      _other -> nil
    end
  end

  defp authed(request, store, handler) do
    Store.transaction(store, fn state ->
      with token when is_binary(token) <- bearer(request),
           {subject_id, kind} <- state.tokens[token],
           %{version: 2} = subject <- state.subjects[subject_id],
           {:ok, actor, subject} <- actor(request, subject, kind) do
        {response, subject} = handler.(request, subject, actor)
        {response, put_in(state, [:subjects, subject_id], subject)}
      else
        {:expired, subject} ->
          {problem("invalid-token", "The grant has expired"),
           put_in(state, [:subjects, subject.id], subject)}

        _invalid ->
          {problem("invalid-token", "Missing or invalid bearer token"), state}
      end
    end)
  end

  defp actor(_request, subject, :person),
    do: {:ok, %{role: "management-client", grant: nil}, subject}

  # §6.2.2: the grant's status is looked up on every request.
  defp actor(request, subject, {:grant, grant_id}) do
    grant = subject.grants[grant_id]
    now = iso(request.now)

    cond do
      is_nil(grant) ->
        :invalid

      grant["status"] == "active" and grant["expiresAt"] != nil and grant["expiresAt"] <= now ->
        subject =
          subject
          |> put_in([:grants, grant_id, "status"], "expired")
          |> append(request, "grant.expired", :authorization_service, %{
            "grantId" => grant_id,
            "data" => %{"reason" => "expiresAt"}
          })

        {:expired, subject}

      grant["status"] == "active" or
          (grant["status"] == "revoked" and fault?(request, :revocation_ignored)) ->
        {:ok, %{role: "context-client", grant: grant}, subject}

      true ->
        :invalid
    end
  end

  defp management?(actor), do: actor.role == "management-client"

  defp denied_categories(request, subject, actor) do
    if management?(actor) or fault?(request, :rule_ignored),
      do: [],
      else: ModelV2.denied_categories(subject.rules, actor.grant)
  end

  defp can_write?(_request, _subject, %{grant: nil}, _entry), do: true

  defp can_write?(request, subject, actor, entry) do
    entry["record"]["status"] == "active" and
      ModelV2.reaches?(actor.grant, entry, "write", nil) and
      not ModelV2.denied?(denied_categories(request, subject, actor), categories_of(entry))
  end

  defp can_read?(_request, _subject, %{grant: nil}, _entry, _purpose), do: true

  defp can_read?(request, subject, actor, entry, purpose) do
    entry["record"]["status"] == "active" and
      not ModelV2.lapsed?(entry, request.now) and
      reaches_for_read?(request, actor.grant, entry, purpose) and
      ModelV2.purpose_permitted?(entry, purpose) and
      not ModelV2.denied?(denied_categories(request, subject, actor), categories_of(entry))
  end

  defp reaches_for_read?(request, grant, entry, purpose) do
    if fault?(request, :no_purpose_check),
      do: Enum.any?(approved(grant), &ModelV2.reaches?(grant, entry, "read", &1)),
      else: ModelV2.reaches?(grant, entry, "read", purpose)
  end

  defp approved(grant),
    do: for(detail <- grant["access"], purpose <- detail["purposes"], do: purpose["code"])

  # Audit (§8) --------------------------------------------------------------------------

  defp append(subject, request, type, initiator, fields) do
    stored =
      %{
        "eventId" => urn_uuid(),
        "eventType" => type,
        "timestamp" => iso(request.now),
        "participants" => participants(request, subject, initiator, fields["retrievalId"]),
        "entryId" => nil,
        "relatedEntryId" => nil,
        "categories" => [],
        "purpose" => nil,
        "purposeDescription" => nil,
        "grantId" => grant_id(initiator),
        "data" => %{}
      }
      |> Map.merge(Map.delete(fields, "retrievalId"))
      |> Map.put("seq", length(subject.audit) + 1)

    %{subject | audit: subject.audit ++ [stored]}
  end

  defp grant_id(%{grant: %{"grantId" => id}}), do: id
  defp grant_id(_initiator), do: nil

  # §3.9: every participant is named; no event names "system".
  defp participants(request, _subject, role, _retrieval) when is_atom(role) do
    name = if role == :provider, do: "hcp-provider", else: "authorization-service"

    %{
      "initiator" => %{"role" => name, "id" => request.base},
      "provider" => %{"id" => request.base}
    }
  end

  defp participants(request, subject, actor, retrieval) do
    client = if actor.grant, do: actor.grant["client"], else: management_client(request)

    base = %{
      "initiator" => %{"role" => actor.role, "id" => client["id"]},
      "clientOperator" => %{"id" => client["operator"]["id"]},
      "requestingParty" => %{"id" => subject.did},
      "authorizingPrincipal" => %{"id" => subject.did},
      "provider" => %{"id" => request.base}
    }

    if retrieval, do: Map.put(base, "retrievalId", retrieval), else: base
  end

  # Entries -------------------------------------------------------------------------

  defp current(subject, id), do: subject.entries[id] && hd(subject.entries[id])
  defp categories_of(entry), do: entry["classification"]["categories"]
  defp put_current(subject, id, entry), do: update_in(subject.entries[id], &[entry | tl(&1)])

  # A Context Client names an entry by the ref it was disclosed under its own
  # grant; a Management Client by its id (§7.4).
  defp resolve(_request, subject, %{grant: nil}, segment),
    do: if(Map.has_key?(subject.entries, segment), do: {:ok, segment}, else: :error)

  defp resolve(request, subject, actor, segment) do
    case subject.refs[segment] do
      {grant_id, id} when is_map_key(subject.entries, id) ->
        if grant_id == actor.grant["grantId"] or fault?(request, :ref_shared),
          do: {:ok, id},
          else: :error

      _unknown ->
        :error
    end
  end

  defp ref(subject, request, grant, id) do
    scope = if fault?(request, :ref_shared), do: "", else: grant["grantId"]
    mac = :crypto.mac(:hmac, :sha256, subject.secret, scope <> id)
    ref = "r_" <> (mac |> Base.url_encode64(padding: false) |> binary_part(0, 16))
    {ref, put_in(subject.refs[ref], {grant["grantId"], id})}
  end

  # What the caller receives for an entry: the entry itself, or a disclosure.
  defp present(subject, _request, %{grant: nil}, entry), do: {entry, subject}

  defp present(subject, request, actor, entry) do
    {ref, subject} = ref(subject, request, actor.grant, entry["id"])
    long? = fault?(request, :long_use_until)
    disclosure = ModelV2.disclosure(entry, actor.grant, ref, request.now, long?)

    disclosure =
      if fault?(request, :leak_id),
        do: Map.merge(disclosure, Map.take(entry, ["id", "subject", "record"])),
        else: disclosure

    {disclosure, subject}
  end

  defp create(request, subject, actor) do
    idempotent(request, subject, "create", fn subject ->
      opts = [subject: subject.did, accept_inferred: fault?(request, :accept_inferred)]

      with :ok <- ModelV2.validate_create(request.json, opts),
           true <- may_assign?(request, subject, actor, request.json) do
        store(request, subject, actor, request.json)
      else
        {:error, slug, detail} ->
          {problem(slug, detail), subject}

        false ->
          {problem("scope-denied", "The request falls outside the caller's grant"), subject}
      end
    end)
  end

  # §4.5: a client assigns only categories its grant lets it write.
  defp may_assign?(_request, _subject, %{grant: nil}, _body), do: true

  defp may_assign?(request, subject, actor, body) do
    categories = body["classification"]["categories"]
    writable = ModelV2.categories_for(actor.grant, "write")

    Enum.all?(categories, &(&1 in writable)) and
      not ModelV2.denied?(denied_categories(request, subject, actor), categories)
  end

  defp store(request, subject, actor, body) do
    id = urn_uuid()

    entry =
      body
      |> Map.drop(["ref"])
      |> Map.merge(%{
        "@context" => @context,
        "schema" => ModelV2.entry_schema(),
        "id" => id,
        "type" => ["ContextEntry"],
        "subject" => %{"id" => subject.did, "relationship" => nil},
        "evidence" => body["evidence"] || [],
        "assertion" => assertion(body["assertion"]),
        "classification" => Map.take(body["classification"], ["categories", "dimension"]),
        "record" => record(request, subject, actor, body, 1)
      })

    subject =
      %{
        subject
        | entries: Map.put(subject.entries, id, [entry]),
          entry_order: subject.entry_order ++ [id]
      }
      |> append(request, "context.created", actor, %{
        "entryId" => id,
        "categories" => categories_of(entry),
        "data" => %{"version" => 1}
      })

    {doc, subject} = present(subject, request, actor, entry)
    {ok(201, doc), subject}
  end

  defp assertion(given), do: Map.merge(%{"confidence" => nil, "validUntil" => nil}, given)

  # §3.5: the provider sets assurance, submittedByClient, authorizedUnder,
  # recordedByProvider, recordedAt and confirmations itself.
  defp record(request, subject, actor, body, version) do
    base = %{
      "status" => "active",
      "version" => version,
      "provenance" => provenance(request, subject, actor, body),
      "relationships" => []
    }

    case get_in(body, ["record", "metadata"]) do
      metadata when is_map(metadata) -> Map.put(base, "metadata", metadata)
      _none -> base
    end
  end

  defp provenance(request, subject, actor, body) do
    given = get_in(body, ["record", "provenance"]) || %{}
    client = if actor.grant, do: actor.grant["client"], else: management_client(request)
    declared? = body["assertion"]["declarationType"] == "person-declared"
    now = iso(request.now)

    %{
      "assertedBy" => %{
        "id" => asserter(subject, client, given, declared?),
        "assurance" => assurance(request, actor, given, declared?)
      },
      "assertedAt" => given["assertedAt"] || now,
      "source" => given["source"] || "person-input",
      "submittedByClient" => Map.take(client, ["id", "name", "operator"]),
      "authorizedUnder" => grant_id(actor) || subject.management_grant,
      "recordedByProvider" => request.base,
      "recordedAt" => now,
      "confirmations" => []
    }
  end

  # A person-declared entry is the Context Subject's; any other names its asserter.
  defp asserter(subject, _client, _given, true), do: subject.did

  defp asserter(_subject, client, given, false),
    do: get_in(given, ["assertedBy", "id"]) || client["id"]

  # §3.7: a person-declared entry is authenticated only when a Management Client wrote it.
  defp assurance(request, actor, given, declared?) do
    claimed = get_in(given, ["assertedBy", "assurance"])

    cond do
      fault?(request, :trust_provenance) and is_binary(claimed) -> claimed
      declared? and management?(actor) -> "authenticated"
      true -> "unverified"
    end
  end

  defp get_entry(request, subject, actor, segment) do
    purpose = request.query["purpose"]

    with {:purpose, true} <- {:purpose, is_binary(purpose) and purpose != ""},
         {:ok, id} <- resolve(request, subject, actor, segment),
         true <- can_read?(request, subject, actor, current(subject, id), purpose),
         {:ok, entry} <- version(subject, id, request.query["version"]) do
      read_one(request, subject, actor, entry, purpose)
    else
      {:purpose, false} -> {problem("malformed-request", "purpose is required"), subject}
      _denied -> {denied(request), subject}
    end
  end

  defp version(subject, id, nil), do: {:ok, current(subject, id)}

  defp version(subject, id, wanted) do
    case Enum.find(subject.entries[id], &(to_string(&1["record"]["version"]) == wanted)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp read_one(request, subject, actor, entry, purpose) do
    retrieval = urn_uuid()
    {doc, subject} = present(subject, request, actor, entry)
    directives = directives(request, subject, actor, [entry])

    subject =
      record_read(subject, request, actor, [{entry, doc}], retrieval, purpose, directives, %{})

    result =
      %{
        "entry" => doc,
        "retrievalId" => retrieval,
        "minimization" => %{"method" => "none"},
        "timestamp" => iso(request.now)
      }
      |> with_directives(actor, directives)

    {ok(200, result), subject}
  end

  defp directives(_request, _subject, %{grant: nil}, _entries), do: []

  defp directives(request, subject, actor, entries) do
    if fault?(request, :no_directives),
      do: [],
      else:
        ModelV2.directives_for(
          subject.directives,
          actor.grant,
          Enum.flat_map(entries, &categories_of/1)
        )
  end

  defp with_directives(result, %{grant: nil}, _directives), do: result
  defp with_directives(result, _actor, directives), do: Map.put(result, "directives", directives)

  # §8.2: context.read lists what was disclosed, by id; the query text is not recorded.
  defp record_read(subject, request, actor, pairs, retrieval, purpose, directives, data) do
    # A Management Client receives the entry itself, with no use-until to record.
    disclosed =
      for {entry, doc} <- pairs do
        item = %{"entryId" => entry["id"], "version" => entry["record"]["version"]}
        if doc["useUntil"], do: Map.put(item, "useUntil", doc["useUntil"]), else: item
      end

    append(subject, request, "context.read", actor, %{
      "retrievalId" => retrieval,
      "entryId" => if(length(pairs) == 1, do: elem(hd(pairs), 0)["id"]),
      "categories" => pairs |> Enum.flat_map(&categories_of(elem(&1, 0))) |> Enum.uniq(),
      "purpose" => purpose,
      "purposeDescription" =>
        json(request)["purposeDescription"] || request.query["purposeDescription"],
      "disclosed" => disclosed,
      "data" => Map.put(data, "directives", Enum.map(directives, & &1["directiveId"]))
    })
  end

  defp json(%{json: json}) when is_map(json), do: json
  defp json(_request), do: %{}

  # Query (§5.2.1, §7) ---------------------------------------------------------------

  defp query(request, subject, actor) do
    body = json(request)

    with nil <- query_error(body),
         {:ok, categories} <- searched(request, actor, body["categories"], body["purpose"]) do
      run_query(request, subject, actor, body, categories)
    else
      :denied ->
        {problem("scope-denied", "The request falls outside the caller's grant"), subject}

      detail ->
        {problem("malformed-request", detail), subject}
    end
  end

  defp query_error(body) do
    max = body["maxEntries"]

    cond do
      not text?(body["query"]) ->
        "query is required"

      not text?(body["purpose"]) ->
        "purpose is required"

      not (is_nil(max) or (is_integer(max) and max > 0)) ->
        "maxEntries must be a positive integer"

      true ->
        nil
    end
  end

  defp text?(value), do: is_binary(value) and value != ""

  # The categories a query searches: those named, each of which the grant must
  # read for the purpose; or, naming none, every category it can.
  defp searched(_request, %{grant: nil}, categories, _purpose) when is_list(categories),
    do: {:ok, categories}

  defp searched(_request, %{grant: nil}, _all, _purpose),
    do: {:ok, Enum.map(ModelV2.described_categories(), & &1["id"])}

  defp searched(request, actor, categories, purpose) do
    readable =
      if fault?(request, :no_purpose_check),
        do: ModelV2.categories_for(actor.grant, "read"),
        else: ModelV2.readable_categories(actor.grant, purpose)

    cond do
      readable == [] -> :denied
      is_nil(categories) -> {:ok, readable}
      is_list(categories) and Enum.all?(categories, &(&1 in readable)) -> {:ok, categories}
      true -> :denied
    end
  end

  defp run_query(request, subject, actor, body, categories) do
    limit = body["maxEntries"] || 5
    limit = if fault?(request, :no_ceiling), do: limit, else: min(limit, 20)
    purpose = body["purpose"]

    candidates =
      subject.entry_order
      |> Enum.map(&current(subject, &1))
      |> Enum.filter(fn entry ->
        Enum.any?(categories_of(entry), &(&1 in categories)) and
          can_read?(request, subject, actor, entry, purpose)
      end)

    ranked =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> {entry, ModelV2.score(body["query"], entry), index} end)
      |> Enum.filter(fn {_entry, score, _index} -> score > 0 end)
      |> Enum.sort_by(fn {_entry, score, index} -> {-score, -index} end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(limit)

    chosen =
      if fault?(request, :pad_results),
        do: Enum.take(ranked ++ (candidates -- ranked), limit),
        else: ranked

    {pairs, subject} =
      Enum.map_reduce(chosen, subject, fn entry, subject ->
        {doc, subject} = present(subject, request, actor, entry)
        {{entry, doc}, subject}
      end)

    retrieval = urn_uuid()
    directives = directives(request, subject, actor, chosen)
    data = %{"maxEntries" => limit, "categoriesSearched" => categories}
    subject = record_read(subject, request, actor, pairs, retrieval, purpose, directives, data)

    result =
      %{
        "entries" => Enum.map(pairs, &elem(&1, 1)),
        "retrievalId" => retrieval,
        "minimization" => %{"method" => "lexical"},
        "categoriesSearched" => categories,
        "timestamp" => iso(request.now)
      }
      |> with_directives(actor, directives)

    result =
      if fault?(request, :count_leak),
        do: Map.put(result, "total", length(candidates)),
        else: result

    {ok(200, result), subject}
  end

  # Onward sharing (§3.12, §5.2.8) ----------------------------------------------------------

  # A client tells the provider what it shared with another organization. The
  # share has already happened, so it is recorded whether or not the grant
  # allowed it.
  defp report_share(_request, subject, %{grant: nil}),
    do:
      {problem("scope-denied", "A share is reported by the client that shared, under its grant"),
       subject}

  defp report_share(request, subject, actor) do
    case share(json(request)) do
      nil ->
        detail = "a share names its recipient, refs, purpose and sharedAt"
        {problem("malformed-request", detail), subject}

      share ->
        record_share(request, subject, actor, share)
    end
  end

  # The members of a report (§5.2.8), or nil where one is missing.
  defp share(%{"recipient" => %{"domain" => domain, "name" => name}, "refs" => [_ | _]} = body)
       when is_binary(domain) and is_binary(name) do
    if is_binary(body["purpose"]) and is_binary(body["sharedAt"]),
      do: Map.take(body, ["recipient", "refs", "purpose", "sharedAt"])
  end

  defp share(_body), do: nil

  defp record_share(request, subject, actor, %{"refs" => refs, "purpose" => purpose} = share) do
    domain = share["recipient"]["domain"]

    entries =
      for ref <- refs,
          {:ok, id} <- [resolve(request, subject, actor, to_string(ref))],
          do: current(subject, id)

    permitted =
      length(entries) == length(refs) and purpose in approved(actor.grant) and
        Enum.all?(entries, &ModelV2.share_permitted?(actor.grant, &1, domain))

    data =
      share
      |> Map.take(["recipient", "purpose", "sharedAt"])
      |> Map.merge(%{"entries" => Enum.map(entries, & &1["id"]), "permitted" => permitted})

    event = %{"purpose" => purpose, "data" => data}

    subject =
      if fault?(request, :share_unrecorded) and not permitted,
        do: subject,
        else: append(subject, request, "context.shared", actor, event)

    if permitted,
      do: {no_content(), subject},
      else: {problem("scope-denied", "The grant does not allow this share"), subject}
  end

  # Revise, withdraw, hard delete ---------------------------------------------------------

  defp revise(request, subject, actor, segment) do
    idempotent(request, subject, "revise:" <> segment, fn subject ->
      body = json(request)

      with {:ok, id} <- resolve(request, subject, actor, segment),
           entry = current(subject, id),
           true <- can_write?(request, subject, actor, entry),
           :ok <-
             ModelV2.validate_revision(body, entry,
               accept_inferred: fault?(request, :accept_inferred)
             ),
           true <- body["expectedVersion"] == entry["record"]["version"] || :stale do
        save_revision(request, subject, actor, entry, body)
      else
        {:error, slug, detail} ->
          {problem(slug, detail), subject}

        :stale ->
          {problem("version-conflict", "expectedVersion is not the current version"), subject}

        _denied ->
          {denied(request), subject}
      end
    end)
  end

  defp save_revision(request, subject, actor, entry, body) do
    id = entry["id"]
    version = entry["record"]["version"] + 1
    kept = Map.take(entry["assertion"], ["declarationType"])

    merged = %{
      "assertion" => Map.merge(kept, body["assertion"] || %{}),
      "record" => body["record"]
    }

    revised =
      Map.merge(entry, %{
        "content" => body["content"],
        "evidence" => body["evidence"] || [],
        "assertion" => assertion(merged["assertion"]),
        "record" => record(request, subject, actor, merged, version)
      })

    subject =
      update_in(subject.entries[id], &[revised | &1])
      |> append(request, "context.revised", actor, %{
        "entryId" => id,
        "categories" => categories_of(revised),
        "data" => %{"version" => version, "reason" => body["reason"]}
      })

    {doc, subject} = present(subject, request, actor, revised)
    {ok(201, doc), subject}
  end

  defp delete(request, subject, actor, segment) do
    hard? = request.query["hardDelete"] == "true"

    if hard? and not management?(actor) do
      {problem("scope-denied", "Hard deletion is a governance operation"), subject}
    else
      idempotent(
        request,
        subject,
        "delete:" <> segment,
        &remove_named(request, &1, actor, segment, hard?)
      )
    end
  end

  defp remove_named(request, subject, actor, segment, hard?) do
    with {:ok, id} <- resolve(request, subject, actor, segment),
         true <- can_write?(request, subject, actor, current(subject, id)) do
      remove(request, subject, actor, segment, id, hard?)
    else
      _denied -> {denied(request), subject}
    end
  end

  defp remove(request, subject, actor, segment, id, hard?) do
    entry = current(subject, id)
    type = if hard?, do: "context.hardDeleted", else: "context.withdrawn"
    name = if management?(actor), do: "entryId", else: "ref"

    subject =
      if hard? and not fault?(request, :hard_delete_keeps) do
        %{
          subject
          | entries: Map.delete(subject.entries, id),
            entry_order: subject.entry_order -- [id]
        }
      else
        put_current(subject, id, put_in(entry, ["record", "status"], "deleted"))
      end

    subject =
      append(subject, request, type, actor, %{
        "entryId" => id,
        "categories" => categories_of(entry),
        "data" => %{"reason" => request.query["reason"]}
      })

    result = %{
      name => segment,
      "status" => "deleted",
      "hardDeleted" => hard?,
      "timestamp" => iso(request.now)
    }

    {ok(200, result), subject}
  end

  # Governance on one entry (§5.4): each names the version the person saw ------------------

  defp versioned(request, subject, id, change) do
    body = json(request)

    # Only a caller let through by the governance_open fault names an entry by ref here.
    entry =
      case subject.refs[id] do
        {_grant, entry_id} -> current(subject, entry_id)
        _id -> current(subject, id)
      end

    cond do
      is_nil(entry) ->
        {denied(request), subject}

      not is_integer(body["expectedVersion"]) ->
        {problem("malformed-request", "expectedVersion is required"), subject}

      body["expectedVersion"] != entry["record"]["version"] and
          not fault?(request, :stale_confirmation) ->
        {problem("version-conflict", "expectedVersion is not the current version"), subject}

      true ->
        change.(entry, body)
    end
  end

  defp confirm(request, subject, actor, id) do
    versioned(request, subject, id, fn entry, body ->
      disposition = body["disposition"]

      if disposition in ["confirmed", "rejected"] do
        entry = confirmed(entry, disposition, subject.did, iso(request.now))
        data = %{"disposition" => disposition, "version" => entry["record"]["version"]}
        changed(request, subject, actor, entry, "context.confirmed", data)
      else
        {problem("malformed-request", "disposition must be confirmed or rejected"), subject}
      end
    end)
  end

  # §3.8, §4.7.3: the record is appended to the current version; a rejected entry is deleted.
  defp confirmed(entry, disposition, subject_id, now) do
    record = %{
      "disposition" => disposition,
      "confirmedBy" => %{"id" => subject_id},
      "confirmedAt" => now
    }

    entry
    |> update_in(["record", "provenance", "confirmations"], &(&1 ++ [record]))
    |> put_in(["record", "status"], if(disposition == "rejected", do: "deleted", else: "active"))
  end

  defp recategorize(request, subject, actor, id) do
    versioned(request, subject, id, fn entry, body ->
      if ModelV2.valid_categories?(body["categories"]) do
        data = %{"from" => categories_of(entry), "to" => body["categories"]}
        entry = put_in(entry, ["classification", "categories"], body["categories"])
        changed(request, subject, actor, entry, "context.recategorized", data)
      else
        {problem("malformed-request", "categories must be categories this implementation holds"),
         subject}
      end
    end)
  end

  defp restrict(request, subject, actor, id) do
    versioned(request, subject, id, fn entry, body ->
      purposes = body["permittedPurposes"]

      if is_nil(purposes) or (is_list(purposes) and Enum.all?(purposes, &is_binary/1)) do
        data = %{"from" => entry["classification"]["permittedPurposes"], "to" => purposes}
        entry = narrowed(entry, purposes)
        changed(request, subject, actor, entry, "context.restricted", data)
      else
        {problem(
           "malformed-request",
           "permittedPurposes must be a list of purpose codes or null"
         ), subject}
      end
    end)
  end

  # §4.2.6: null lifts the Authorizing Principal's narrowing.
  defp narrowed(entry, nil),
    do: update_in(entry, ["classification"], &Map.delete(&1, "permittedPurposes"))

  defp narrowed(entry, purposes),
    do: put_in(entry, ["classification", "permittedPurposes"], purposes)

  defp changed(request, subject, actor, entry, type, data) do
    subject =
      subject
      |> put_current(entry["id"], entry)
      |> append(request, type, actor, %{
        "entryId" => entry["id"],
        "categories" => categories_of(entry),
        "data" => data
      })

    {ok(200, entry), subject}
  end

  # Grants (§6.1.5, §6.2) -----------------------------------------------------------------

  defp grant_object(grant), do: Map.drop(grant, ["token"])

  # A Context Client reading its own grant sees narrowed entries by ref (§5.2.6).
  defp own_grant(subject, request, grant) do
    {access, subject} =
      Enum.map_reduce(grant["access"], subject, fn detail, subject ->
        case detail["narrowedTo"] do
          %{"entryIds" => ids} ->
            {refs, subject} = Enum.map_reduce(ids, subject, &ref(&2, request, grant, &1))
            {Map.put(detail, "narrowedTo", %{"entryIds" => refs}), subject}

          _unnarrowed ->
            {detail, subject}
        end
      end)

    {grant |> grant_object() |> Map.put("access", access), subject}
  end

  defp list_grants(request, subject, %{grant: nil}) do
    status = request.query["status"] || "active"

    grants =
      subject.grant_order
      |> Enum.map(&subject.grants[&1])
      |> Enum.filter(&(&1["status"] == status))
      |> Enum.map(&grant_object/1)

    {ok(200, %{"grants" => grants}), subject}
  end

  defp list_grants(request, subject, actor) do
    {grant, subject} = own_grant(subject, request, actor.grant)
    {ok(200, %{"grants" => [grant]}), subject}
  end

  # A Management Client revokes any grant; a Context Client only relinquishes its own (§5.2.7).
  defp revoke(request, subject, actor, id) do
    grant = subject.grants[id]

    cond do
      is_nil(grant) or not (management?(actor) or actor.grant["grantId"] == id) ->
        {problem("scope-denied", "The request falls outside the caller's grant"), subject}

      grant["status"] != "active" ->
        {no_content(), subject}

      true ->
        {no_content(), end_grant(subject, request, actor, id)}
    end
  end

  defp end_grant(subject, request, initiator, id) do
    subject
    |> put_in([:grants, id, "status"], "revoked")
    |> append(request, "grant.revoked", initiator, %{"grantId" => id})
  end

  # Audit log and export ------------------------------------------------------------------

  defp public_event(event), do: Map.delete(event, "seq")

  defp audit(request, subject, _actor) do
    with {:ok, limit} <- parse_limit(request.query["limit"]),
         {:ok, after_seq} <- parse_cursor(subject, request.query["cursor"], request) do
      remaining = Enum.filter(subject.audit, &(&1["seq"] > after_seq))
      page = Enum.take(remaining, limit)

      {next, subject} =
        if length(remaining) > limit,
          do: issue_cursor(subject, List.last(page)["seq"], request),
          else: {nil, subject}

      {ok(200, %{"events" => Enum.map(page, &public_event/1), "nextCursor" => next}), subject}
    else
      {:error, detail} -> {problem("malformed-request", detail), subject}
    end
  end

  defp parse_limit(nil), do: {:ok, 50}

  defp parse_limit(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, min(number, 200)}
      _invalid -> {:error, "limit must be a positive integer"}
    end
  end

  defp parse_cursor(_subject, nil, _request), do: {:ok, 0}

  defp parse_cursor(subject, cursor, request) do
    if fault?(request, :plain_cursor) do
      case Integer.parse(cursor) do
        {seq, ""} -> {:ok, seq}
        _invalid -> {:error, "unreadable cursor"}
      end
    else
      case subject.cursors[cursor] do
        nil -> {:error, "unreadable cursor"}
        seq -> {:ok, seq}
      end
    end
  end

  # §9.5: a cursor is a server-side handle, never a position a client can read.
  defp issue_cursor(subject, seq, request) do
    if fault?(request, :plain_cursor) do
      {Integer.to_string(seq), subject}
    else
      cursor = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      {cursor, %{subject | cursors: Map.put(subject.cursors, cursor, seq)}}
    end
  end

  defp export(request, subject, actor) do
    include = csv(request.query["include"])
    exclude = csv(request.query["exclude"])

    options = %{
      "excludeDeleted" => "deleted" in exclude,
      "includeVersions" => "versions" in include,
      "includeAudit" => "audit" in include
    }

    histories = Enum.map(subject.entry_order, &subject.entries[&1])

    histories =
      if options["excludeDeleted"],
        do: Enum.reject(histories, &(hd(&1)["record"]["status"] == "deleted")),
        else: histories

    subject =
      append(subject, request, "context.exported", actor, %{"data" => %{"options" => options}})

    document =
      %{
        "@context" => @context,
        "type" => "ContextExport",
        "schema" => "https://hcp.example/spec/export/2.0",
        "subject" => %{"id" => subject.did},
        "exportedBy" => request.base,
        "exportedAt" => iso(request.now),
        "options" => options,
        "entries" => Enum.map(histories, &hd/1),
        "rules" => subject.rules,
        "directives" => subject.directives,
        "delegations" => []
      }
      |> put_if(options["includeVersions"], "versions", Enum.flat_map(histories, &tl/1))
      |> put_if(options["includeAudit"], "audit", Enum.map(subject.audit, &public_event/1))

    {ok(200, document), subject}
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, _false, _key, _value), do: map

  defp csv(nil), do: []
  defp csv(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # Standing rules and directives (§6.3, §6.4) ---------------------------------------------

  defp list(_request, subject, _actor, kind),
    do: {ok(200, %{kind => Map.fetch!(subject, key(kind))}), subject}

  defp key("rules"), do: :rules
  defp key("directives"), do: :directives

  defp set(request, subject, actor, "rules") do
    body = json(request)

    if list_of_strings?(body["operators"]) or list_of_strings?(body["requires"]) do
      rule =
        body
        |> Map.take(["operators", "requires", "categories"])
        |> Map.merge(set_by(request, "ruleId"))
        |> Map.put("effect", "deny")

      subject =
        %{subject | rules: subject.rules ++ [rule]}
        |> append(request, "rule.set", actor, %{"data" => Map.drop(rule, ["effect", "createdAt"])})
        |> revoke_denied(request)

      {ok(201, rule), subject}
    else
      {problem("malformed-request", "a standing rule names operators, requires, or both"),
       subject}
    end
  end

  defp set(request, subject, actor, "directives") do
    body = json(request)

    if is_binary(body["action"]) and body["effect"] in ~w(deny ask-first permit) and
         is_binary(body["text"]) do
      directive =
        body
        |> Map.take(["action", "effect", "text", "categories", "operators"])
        |> Map.merge(set_by(request, "directiveId"))

      subject =
        %{subject | directives: subject.directives ++ [directive]}
        |> append(request, "directive.set", actor, %{
          "data" => Map.drop(directive, ["text", "createdAt"])
        })

      {ok(201, directive), subject}
    else
      {problem("malformed-request", "a directive carries action, effect and text"), subject}
    end
  end

  defp set_by(request, id_member),
    do: %{id_member => urn_uuid(), "setBy" => "context-subject", "createdAt" => iso(request.now)}

  defp list_of_strings?(value),
    do: is_list(value) and value != [] and Enum.all?(value, &is_binary/1)

  defp unset(request, subject, actor, kind, id) do
    {id_member, type} =
      if kind == "rules",
        do: {"ruleId", "rule.removed"},
        else: {"directiveId", "directive.removed"}

    held = Map.fetch!(subject, key(kind))

    case Enum.find(held, &(&1[id_member] == id)) do
      nil ->
        {denied(request), subject}

      item ->
        subject =
          subject
          |> Map.put(key(kind), held -- [item])
          |> append(request, type, actor, %{
            "data" => Map.drop(item, ["effect", "text", "createdAt"])
          })

        {no_content(), subject}
    end
  end

  # §6.3: a rule covering every category a grant reaches revokes the grant.
  defp revoke_denied(subject, request) do
    if fault?(request, :rule_ignored), do: subject, else: revoke_covered(subject, request)
  end

  defp revoke_covered(subject, request) do
    subject.grant_order
    |> Enum.map(&subject.grants[&1])
    |> Enum.filter(&(&1["status"] == "active" and fully_denied?(subject, &1)))
    |> Enum.reduce(subject, &end_grant(&2, request, :provider, &1["grantId"]))
  end

  defp fully_denied?(subject, grant) do
    case ModelV2.denied_categories(subject.rules, grant) do
      :all -> true
      denied -> Enum.all?(Enum.flat_map(grant["access"], & &1["categories"]), &(&1 in denied))
    end
  end

  # Idempotency (§9.6) -------------------------------------------------------------------

  defp idempotent(request, subject, endpoint, operation) do
    key = request.headers["idempotency-key"]

    if is_nil(key) or fault?(request, :no_idempotency) do
      operation.(subject)
    else
      fingerprint =
        :crypto.hash(:sha256, request.raw <> "?" <> URI.encode_query(Enum.sort(request.query)))

      case subject.idempotency[{endpoint, key}] do
        {^fingerprint, response} ->
          {response, subject}

        {_other, _response} ->
          {problem("idempotency-conflict", "The key was used with a different body"), subject}

        nil ->
          remember(operation.(subject), {endpoint, key}, fingerprint)
      end
    end
  end

  # Only a success is replayed; a failed request may be retried with the same key.
  defp remember({{status, _, _, _} = response, subject}, slot, fingerprint)
       when status in 200..299,
       do: {response, put_in(subject.idempotency[slot], {fingerprint, response})}

  defp remember(result, _slot, _fingerprint), do: result

  # The conformance hook (docs/HOOK.md) ----------------------------------------------

  defp hook(request, path, store) do
    if bearer(request) == request.hook_secret,
      do: hook_route(request, path, store),
      else: problem("invalid-token", "The conformance hook secret is missing or wrong")
  end

  defp hook_route(%{method: "POST"}, ["subjects"], store) do
    id = String.replace_prefix(urn_uuid(), "urn:uuid:", "")
    token = "ref-person-" <> random_token()

    subject = %{
      version: 2,
      id: id,
      did: "urn:hcp:subject:" <> id,
      person_token: token,
      secret: :crypto.strong_rand_bytes(32),
      management_grant: urn_uuid(),
      entries: %{},
      entry_order: [],
      refs: %{},
      grants: %{},
      grant_order: [],
      rules: [],
      directives: [],
      audit: [],
      idempotency: %{},
      cursors: %{}
    }

    Store.transaction(store, fn state -> {:ok, Store.put_subject(state, subject)} end)

    {201, %{"subjectId" => id, "subjectDid" => subject.did, "personToken" => token},
     "application/json", []}
  end

  defp hook_route(%{method: "POST"} = request, ["subjects", subject_id, "grants"], store) do
    Store.transaction(store, fn state ->
      case state.subjects[subject_id] do
        %{version: 2} = subject -> issue_grant(request, state, subject)
        _missing -> {not_found("No such subject"), state}
      end
    end)
  end

  defp hook_route(%{method: "DELETE"}, ["subjects", subject_id], store) do
    Store.transaction(store, fn state -> {no_content(), Store.drop_subject(state, subject_id)} end)
  end

  defp hook_route(_request, _path, _store), do: not_found("No such hook route")

  defp grant_request_error(body) do
    seconds = body["expiresInSeconds"]

    cond do
      not is_binary(body["clientId"]) ->
        "clientId is required"

      not is_binary(body["clientName"]) ->
        "clientName is required"

      body["grantType"] not in ["temporary", "persistent"] ->
        "grantType must be temporary or persistent"

      body["grantType"] == "temporary" and not (is_integer(seconds) and seconds in 1..86_400) ->
        "a temporary grant lasts at most 24 hours"

      true ->
        ModelV2.access_error(body["access"])
    end
  end

  defp issue_grant(request, state, subject) do
    body = json(request)

    case grant_request_error(body) do
      nil -> issue_valid_grant(request, state, subject, body)
      detail -> {problem("malformed-request", detail), state}
    end
  end

  defp issue_valid_grant(request, state, subject, body) do
    id = urn_uuid()
    token = "ref-grant-" <> random_token()
    temporary? = body["grantType"] == "temporary"
    expires = if temporary?, do: iso(DateTime.add(request.now, body["expiresInSeconds"], :second))
    access = Enum.map(body["access"], &Map.put(&1, "type", ModelV2.access_type()))

    grant = %{
      "grantId" => id,
      "subject" => %{"id" => subject.did},
      "authorizingPrincipal" => %{"id" => subject.did},
      "client" => %{
        "id" => body["clientId"],
        "name" => body["clientName"],
        "operator" => body["operator"] || operator(request)
      },
      "requestingParty" => %{
        "type" => "person",
        "id" => subject.did,
        "name" => "Conformance subject"
      },
      "access" => access,
      "scopes" => ModelV2.scopes(access),
      "grantType" => body["grantType"],
      "issuedAt" => iso(request.now),
      "expiresAt" => expires,
      "status" => "active",
      "token" => token
    }

    # §6.3: no grant reaches a category a standing rule denies its operator.
    if fully_or_partly_denied?(subject, grant) do
      {problem("malformed-request", "a standing rule denies this operator a requested category"),
       state}
    else
      data = %{
        "access" => access,
        "grantType" => grant["grantType"],
        "expiresAt" => expires,
        "modality" => "conformance-hook",
        "acr" => "urn:hcp:conformance:hook"
      }

      subject =
        %{
          subject
          | grants: Map.put(subject.grants, id, grant),
            grant_order: subject.grant_order ++ [id]
        }
        |> append(request, "grant.issued", :authorization_service, %{
          "grantId" => id,
          "data" => data
        })

      state =
        state
        |> put_in([:subjects, subject.id], subject)
        |> put_in([:tokens, token], {subject.id, {:grant, id}})

      {{201, %{"grantId" => id, "token" => token, "expiresAt" => expires}, "application/json",
        []}, state}
    end
  end

  defp fully_or_partly_denied?(subject, grant) do
    denied = ModelV2.denied_categories(subject.rules, grant)
    ModelV2.denied?(denied, Enum.flat_map(grant["access"], & &1["categories"]))
  end

  # Helpers ----------------------------------------------------------------------------

  defp iso(datetime), do: DateTime.to_iso8601(datetime)
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp urn_uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "urn:uuid:#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end
end
