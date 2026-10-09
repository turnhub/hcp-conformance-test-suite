defmodule HcpConformance.Reference.Server do
  @moduledoc """
  A small, in-memory HCP v1 implementation of the RESTful transport, with the
  conformance hook (docs/HOOK.md).

  It exists for two reasons. The suite's own tests run every check against it,
  once as written and once with deliberate faults (`faults:`), proving that each
  check passes a conformant target and catches the defect it targets. And a hosted
  suite can mount it, so anyone can see a passing run and the hook in action.

  It is a reference for behaviour, not a product: one envelope form (grouped),
  Tier 1 only, lexical relevance, first-party authorization, no persistence.

  Options: `store` (a `Reference.Store`), `hook_secret`, `base_url` (otherwise
  derived from the request), `faults` (a list of fault atoms, see `@faults`).
  """

  @behaviour Plug

  import Plug.Conn

  alias HcpConformance.Reference.Store

  @version "1.0"
  @problem_base "https://hcp.me/problems/"
  @context ["https://www.w3.org/ns/credentials/v2", "https://hcp.me/contexts/v1"]
  @categories ~w(general_preferences goals_and_constraints health_context education_learner_profile work_context
                 purchase_history_preferences values_and_ethics location_context coordination_context)
  @titles %{
    "invalid-token" => "Missing or invalid bearer token",
    "scope-denied" => "Outside authorized scopes",
    "malformed-request" => "Request body fails validation",
    "idempotency-conflict" => "Idempotency key reused with a differing body",
    "rate-limited" => "Rate limit exceeded",
    "unsupported-version" => "Requested protocol version not supported"
  }
  @statuses %{
    "invalid-token" => 401,
    "scope-denied" => 403,
    "malformed-request" => 422,
    "idempotency-conflict" => 409,
    "rate-limited" => 429,
    "unsupported-version" => 400
  }

  # Deliberate defects, one per behaviour a check guards. Tests switch them on to
  # prove the matching check fails.
  @faults ~w(omit_hcp_version not_found_for_agent pad_results no_redaction plain_cursor no_idempotency
             no_conflicts ignore_version_header leak_conflicted_versions export_open no_ceiling
             no_purpose_check hard_delete_keeps revocation_ignored wrong_media_type count_leak)a

  @doc "The fault switches the server understands."
  @spec faults() :: [atom()]
  def faults, do: @faults

  @impl Plug
  def init(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      hook_secret: Keyword.get(opts, :hook_secret, "reference-hook-secret"),
      base_url: Keyword.get(opts, :base_url),
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
      hook_secret: opts.hook_secret
    }

    {status, body, type, headers} = route(request, opts.store)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)

    case body do
      nil ->
        send_resp(conn, status, "")

      body ->
        conn
        |> put_resp_content_type(type, nil)
        |> send_resp(status, Jason.encode!(body))
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

  defp ok(request, status, body) do
    body =
      if fault?(request, :omit_hcp_version),
        do: body,
        else: Map.put(body, "hcp_version", @version)

    type =
      if fault?(request, :wrong_media_type), do: "application/json", else: "application/ld+json"

    {status, body, type, []}
  end

  defp problem(slug, detail) do
    status = Map.fetch!(@statuses, slug)

    body = %{
      "type" => @problem_base <> slug,
      "title" => Map.fetch!(@titles, slug),
      "status" => status,
      "detail" => detail,
      "hcp_version" => @version
    }

    headers = if slug == "rate-limited", do: [{"retry-after", "1"}], else: []
    {status, body, "application/problem+json", headers}
  end

  defp not_found(detail) do
    {404,
     %{
       "type" => "about:blank",
       "title" => "Not found",
       "status" => 404,
       "detail" => detail,
       "hcp_version" => @version
     }, "application/problem+json", []}
  end

  defp fault?(request, fault), do: MapSet.member?(request.faults, fault)

  # Routing ---------------------------------------------------------------------

  defp route(%{path: ["conformance-hook" | rest]} = request, store),
    do: hook(request, rest, store)

  defp route(request, store) do
    version = request.headers["hcp-version"]

    if version not in [nil, @version] and not fault?(request, :ignore_version_header) do
      problem("unsupported-version", "This implementation speaks hcp_version #{@version}")
    else
      dispatch(request, store)
    end
  end

  defp dispatch(%{method: "GET", path: [".well-known", "hcp-configuration"]} = request, _store),
    do: discovery(request)

  defp dispatch(%{method: "POST", path: ["v1", "preferences", "search"]} = request, store),
    do: authed(request, store, &search/3)

  defp dispatch(%{method: "POST", path: ["v1", "preferences"]} = request, store),
    do: authed(request, store, &add/3)

  defp dispatch(%{method: "GET", path: ["v1", "preferences", id]} = request, store),
    do: authed(request, store, &get_entry(&1, &2, &3, id))

  defp dispatch(%{method: "PUT", path: ["v1", "preferences", id]} = request, store),
    do: authed(request, store, &update(&1, &2, &3, id))

  defp dispatch(%{method: "DELETE", path: ["v1", "preferences", id]} = request, store),
    do: authed(request, store, &delete(&1, &2, &3, id))

  defp dispatch(%{method: "GET", path: ["v1", "grants"]} = request, store),
    do: authed(request, store, &list_grants/3)

  defp dispatch(%{method: "DELETE", path: ["v1", "grants", id]} = request, store),
    do: authed(request, store, &revoke(&1, &2, &3, id))

  defp dispatch(%{method: "GET", path: ["v1", "audit"]} = request, store),
    do: authed(request, store, &audit/3)

  defp dispatch(%{method: "GET", path: ["v1", "export"]} = request, store),
    do: authed(request, store, &export/3)

  defp dispatch(_request, _store), do: not_found("No such route")

  defp discovery(request) do
    base = request.base

    ok(request, 200, %{
      "issuer" => base,
      "preferences_endpoint" => base <> "/v1/preferences",
      "grants_endpoint" => base <> "/v1/grants",
      "audit_endpoint" => base <> "/v1/audit",
      "export_endpoint" => base <> "/v1/export",
      "supported_categories" => @categories,
      "supported_transports" => ["rest"],
      "conformance_level" => "HCP-v1-Core",
      "authorization_profile" => "first-party",
      "envelope_form" => "grouped",
      "minimization_method" => "lexical",
      "audit_durability" => %{"default" => "synchronous"},
      "pagination" => %{"audit" => "cursor"},
      "problem_type_base" => @problem_base,
      "rate_limits" => %{"documentation_url" => base <> "/.well-known/hcp-configuration"}
    })
  end

  # Authentication ----------------------------------------------------------------

  defp bearer(request) do
    case request.headers["authorization"] do
      "Bearer " <> token -> String.trim(token)
      "bearer " <> token -> String.trim(token)
      _other -> nil
    end
  end

  # Resolves the bearer to a subject and an actor, runs `handler` against the
  # subject inside one store transaction, and writes the subject back.
  defp authed(request, store, handler) do
    Store.transaction(store, fn state ->
      with token when is_binary(token) <- bearer(request),
           {subject_id, kind} <- state.tokens[token],
           %{} = subject <- state.subjects[subject_id],
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
    do: {:ok, %{type: "user", id: subject.did, grant: nil}, subject}

  defp actor(request, subject, {:grant, grant_id}) do
    grant = subject.grants[grant_id]
    now = iso(request.now)

    cond do
      is_nil(grant) ->
        :invalid

      grant.status == "active" and grant.expires_at != nil and grant.expires_at <= now ->
        subject =
          subject
          |> put_in([:grants, grant_id, :status], "expired")
          |> append(request, %{
            "eventType" => "grant.expired",
            "actorId" => "system",
            "actorType" => "system",
            "grantId" => grant_id
          })

        {:expired, subject}

      grant.status == "active" or
          (grant.status == "revoked" and fault?(request, :revocation_ignored)) ->
        {:ok, %{type: "agent", id: grant.client_id, grant: grant}, subject}

      true ->
        :invalid
    end
  end

  defp user?(actor), do: actor.type == "user"

  defp allowed?(actor, category, action) do
    user?(actor) or "hcp:#{category}:#{action}" in actor.grant.scopes
  end

  # Rule 4 of §4.1.5.1: a restriction on the scope narrows what the grant reaches.
  defp within_restrictions?(actor, category, action, entry_id) do
    user?(actor) or
      Enum.all?(actor.grant.restrictions || [], fn restriction ->
        restriction["scope"] != "hcp:#{category}:#{action}" or
          entry_id in (get_in(restriction, ["narrowedTo", "entryIds"]) || [])
      end)
  end

  # Audit ---------------------------------------------------------------------------

  defp append(subject, request, event) do
    seq = length(subject.audit) + 1

    stored =
      Map.merge(
        %{
          "eventId" => urn_uuid(),
          "timestamp" => iso(request.now),
          "entryId" => nil,
          "relatedEntryId" => nil,
          "category" => nil,
          "purpose" => nil,
          "grantId" => nil,
          "detail" => nil
        },
        event
      )
      |> Map.put("seq", seq)

    %{subject | audit: subject.audit ++ [stored]}
  end

  defp actor_event(actor, fields) do
    Map.merge(
      %{
        "actorId" => actor.id,
        "actorType" => actor.type,
        "grantId" => actor.grant && actor.grant.id
      },
      fields
    )
  end

  # Entries -------------------------------------------------------------------------

  defp current(subject, id), do: subject.entries[id] && hd(subject.entries[id].versions)
  defp status_of(envelope), do: envelope["record"]["status"]
  defp category_of(envelope), do: envelope["record"]["category"]

  defp put_current(subject, id, envelope) do
    update_in(subject, [:entries, id, :versions], fn [_current | older] -> [envelope | older] end)
  end

  defp push_version(subject, id, envelope),
    do: update_in(subject, [:entries, id, :versions], &[envelope | &1])

  defp redact(envelope, actor, request) do
    if user?(actor) or fault?(request, :no_redaction) do
      envelope
    else
      update_in(
        envelope,
        ["record", "provenance"],
        &Map.drop(&1 || %{}, ["source", "capturedBy"])
      )
    end
  end

  defp redacted_fields(actor, request) do
    if user?(actor) or fault?(request, :no_redaction),
      do: [],
      else: ["record.provenance.source", "record.provenance.capturedBy"]
  end

  @doc false
  def validate_entry(%{"credentialType" => "VerifiablePreference"}),
    do: {:error, "Tier 2 entries are not supported"}

  def validate_entry(%{"claim" => claim, "record" => record})
      when is_map(claim) and is_map(record) do
    case claim_error(claim) || record_error(record) do
      nil -> :ok
      message -> {:error, message}
    end
  end

  def validate_entry(body) when is_map(body),
    do: {:error, "claim and record are required (grouped form)"}

  def validate_entry(_body), do: {:error, "the body must be an HCPEntry object"}

  defp claim_error(claim) do
    cond do
      not match?(%{"issuer" => %{"id" => id}} when is_binary(id), claim) ->
        "claim.issuer.id is required"

      not match?(%{"subject" => %{"id" => id}} when is_binary(id), claim) ->
        "claim.subject.id is required"

      not match?(
        %{"preference" => preference} when is_binary(preference) or is_map(preference),
        claim["subject"]
      ) ->
        "claim.subject.preference is required"

      true ->
        nil
    end
  end

  defp record_error(record) do
    cond do
      not registered_category?(record["category"]) ->
        "record.category must be a registered category"

      not (is_nil(record["dimension"]) or is_binary(record["dimension"])) ->
        "record.dimension must be a string"

      message = declaration_error(record) ->
        message

      not match?(%{"provenance" => %{"source" => source}} when is_binary(source), record) ->
        "record.provenance.source is required"

      true ->
        nil
    end
  end

  defp registered_category?(category) when is_binary(category),
    do: category in @categories or String.starts_with?(category, "hcp-custom:")

  defp registered_category?(_category), do: false

  # Only a model-inferred entry carries a confidence, and it must.
  defp declaration_error(%{"declarationType" => "model-inferred", "confidence" => confidence})
       when confidence in ["high", "medium", "low"],
       do: nil

  defp declaration_error(%{"declarationType" => "model-inferred"}),
    do: "model-inferred entries require confidence"

  defp declaration_error(%{"declarationType" => declaration} = record)
       when declaration in ["user-declared", "issuer-attested"] do
    if is_nil(record["confidence"]),
      do: nil,
      else: "confidence must be null unless model-inferred"
  end

  defp declaration_error(_record), do: "record.declarationType is required"

  defp add(request, subject, actor) do
    idempotent(request, subject, "POST /v1/preferences", fn subject ->
      with :ok <- validate_entry(request.json),
           category = request.json["record"]["category"],
           true <- allowed?(actor, category, "write") || :denied do
        create(request, subject, actor)
      else
        :denied ->
          {problem("scope-denied", "The grant does not allow writing this category"), subject}

        {:error, detail} ->
          {problem("malformed-request", detail), subject}
      end
    end)
  end

  defp create(request, subject, actor) do
    body = request.json
    record = body["record"]
    provenance = record["provenance"]
    id = urn_uuid()

    envelope = %{
      "@context" => @context,
      "id" => id,
      "type" => ["HCPEntry"],
      "credentialType" => "NLPreference",
      "claim" => %{
        "issuer" => body["claim"]["issuer"],
        "issuanceDate" => iso(request.now),
        "expirationDate" => body["claim"]["expirationDate"],
        "subject" => Map.put_new(body["claim"]["subject"], "relationship", nil)
      },
      "record" => %{
        "category" => record["category"],
        "dimension" => record["dimension"],
        "declarationType" => record["declarationType"],
        "confidence" => record["confidence"],
        "status" => "active",
        "version" => 1,
        "previousVersion" => nil,
        "provenance" => %{
          "source" => provenance["source"],
          "capturedAt" => provenance["capturedAt"] || iso(request.now),
          "capturedBy" => provenance["capturedBy"],
          "userVerified" => provenance["userVerified"] == true
        }
      }
    }

    subject =
      %{
        subject
        | entries: Map.put(subject.entries, id, %{versions: [envelope]}),
          entry_order: subject.entry_order ++ [id]
      }
      |> append(
        request,
        actor_event(actor, %{
          "eventType" => "preference.created",
          "entryId" => id,
          "category" => record["category"]
        })
      )
      |> detect_conflicts(request, id)

    {ok(request, 201, redact(current(subject, id), actor, request)), subject}
  end

  defp search(request, subject, actor) do
    body = json_object(request)
    categories = body["categories"]
    max = body["maxEntries"]
    detail = body["responseDetail"] || "full"

    cond do
      not non_empty_list?(categories, &is_binary/1) ->
        {problem("malformed-request", "categories is required"), subject}

      not (purpose?(body["purpose"]) or fault?(request, :no_purpose_check)) ->
        {problem("malformed-request", "purpose is required"), subject}

      not optional?(max, &positive_integer?/1) ->
        {problem("malformed-request", "maxEntries must be a positive integer"), subject}

      detail not in ["full", "minimal"] ->
        {problem("malformed-request", "responseDetail must be full or minimal"), subject}

      not Enum.all?(categories, &allowed?(actor, &1, "read")) ->
        {problem("scope-denied", "A requested category is outside the grant"), subject}

      true ->
        run_search(request, subject, actor, body, categories, detail)
    end
  end

  defp run_search(request, subject, actor, body, categories, detail) do
    limit = body["maxEntries"] || 5
    limit = if fault?(request, :no_ceiling), do: limit, else: min(limit, 20)
    query = tokens(body["query"])

    candidates =
      subject.entry_order
      |> Enum.with_index()
      |> Enum.map(fn {id, index} -> {current(subject, id), index} end)
      |> Enum.filter(fn {envelope, _index} ->
        envelope != nil and status_of(envelope) == "active" and
          category_of(envelope) in categories and
          within_restrictions?(actor, category_of(envelope), "read", envelope["id"])
      end)

    scored =
      candidates
      |> Enum.map(fn {envelope, index} -> {envelope, index, score(query, envelope)} end)
      |> Enum.filter(fn {_envelope, _index, score} -> score > 0 end)
      |> Enum.sort(&ranks_before?/2)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(limit)

    padded =
      if fault?(request, :pad_results) do
        extra = candidates |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in scored))
        Enum.take(scored ++ extra, limit)
      else
        scored
      end

    entries = Enum.map(padded, &shape(&1, actor, request, detail))
    purpose = body["purpose"]

    subject =
      append(
        subject,
        request,
        actor_event(actor, %{
          "eventType" => "preference.read",
          "category" => Enum.join(categories, ","),
          "purpose" => purpose
        })
      )

    response = %{
      "entries" => entries,
      "retrievalId" => urn_uuid(),
      "minimization" => %{
        "method" => "lexical",
        "redactedFields" => redacted_fields(actor, request)
      },
      "categoriesSearched" => categories,
      "timestamp" => iso(request.now)
    }

    response =
      if fault?(request, :count_leak),
        do: Map.put(response, "total", length(candidates)),
        else: response

    {ok(request, 200, response), subject}
  end

  # Higher score first, then newer issuanceDate, then later insertion.
  defp ranks_before?({a, index_a, score_a}, {b, index_b, score_b}) do
    date_a = a["claim"]["issuanceDate"]
    date_b = b["claim"]["issuanceDate"]

    cond do
      score_a != score_b -> score_a > score_b
      date_a != date_b -> date_a > date_b
      true -> index_a >= index_b
    end
  end

  # §3.1.1: a minimal Tier 1 entry is its id, category, dimension and value.
  defp shape(envelope, _actor, _request, "minimal") do
    %{
      "id" => envelope["id"],
      "record" => Map.take(envelope["record"], ["category", "dimension"]),
      "value" => envelope["claim"]["subject"]["preference"]
    }
  end

  defp shape(envelope, actor, request, _full), do: redact(envelope, actor, request)

  # Distinct lowercase words of two or more letters or digits.
  defp tokens(nil), do: []

  defp tokens(text) when is_binary(text) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) > 1))
    |> Enum.uniq()
  end

  defp tokens(other), do: tokens(Jason.encode!(other))

  defp score(query, envelope) do
    words = tokens(envelope["claim"]["subject"]["preference"])
    Enum.count(query, &(&1 in words))
  end

  defp get_entry(request, subject, actor, id) do
    purpose = request.query["purpose"]
    version = request.query["version"]
    envelope = current(subject, id)

    cond do
      not purpose?(purpose) ->
        {problem("malformed-request", "purpose is required"), subject}

      is_nil(envelope) and fault?(request, :not_found_for_agent) and not user?(actor) ->
        {not_found("No such entry"), subject}

      is_nil(envelope) or not readable?(request, actor, envelope, version) ->
        {problem("scope-denied", "Entry is outside the caller's scopes or does not exist"),
         subject}

      true ->
        read_version(request, subject, actor, id, version, purpose)
    end
  end

  defp readable?(request, actor, envelope, version) do
    category = category_of(envelope)

    (user?(actor) or not hidden_from_agent?(envelope, version, request)) and
      allowed?(actor, category, "read") and
      within_restrictions?(actor, category, "read", envelope["id"])
  end

  defp json_object(%{json: json}) when is_map(json), do: json
  defp json_object(_request), do: %{}

  defp purpose?(purpose), do: is_binary(purpose) and purpose != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp within_a_day?(seconds), do: positive_integer?(seconds) and seconds <= 86_400
  defp optional?(value, valid?), do: is_nil(value) or valid?.(value)

  defp non_empty_list?(value, valid?),
    do: is_list(value) and value != [] and Enum.all?(value, valid?)

  defp hidden_from_agent?(envelope, version, request) do
    status_of(envelope) in ["conflicted", "deleted"] and
      not (version != nil and fault?(request, :leak_conflicted_versions))
  end

  defp read_version(request, subject, actor, id, version, purpose) do
    selected =
      case version && Integer.parse(version) do
        nil ->
          current(subject, id)

        {number, ""} ->
          Enum.find(subject.entries[id].versions, &(&1["record"]["version"] == number))

        _invalid ->
          :invalid
      end

    case selected do
      :invalid ->
        {problem("malformed-request", "version must be an integer"), subject}

      nil ->
        {problem("scope-denied", "No such version"), subject}

      envelope ->
        subject =
          append(
            subject,
            request,
            actor_event(actor, %{
              "eventType" => "preference.read",
              "entryId" => id,
              "category" => category_of(envelope),
              "purpose" => purpose
            })
          )

        {ok(request, 200, %{
           "entry" => redact(envelope, actor, request),
           "retrievalId" => urn_uuid(),
           "minimization" => %{
             "method" => "lexical",
             "redactedFields" => redacted_fields(actor, request)
           },
           "timestamp" => iso(request.now)
         }), subject}
    end
  end

  defp writable(subject, actor, id) do
    envelope = current(subject, id)

    cond do
      is_nil(envelope) -> :denied
      user?(actor) -> {:ok, envelope}
      status_of(envelope) in ["conflicted", "deleted"] -> :denied
      not allowed?(actor, category_of(envelope), "write") -> :denied
      not within_restrictions?(actor, category_of(envelope), "write", id) -> :denied
      true -> {:ok, envelope}
    end
  end

  defp update(request, subject, actor, id) do
    idempotent(request, subject, "PUT /v1/preferences/" <> id, fn subject ->
      text = is_map(request.json) && request.json["updatedPreference"]

      with true <- is_binary(text) || :malformed,
           {:ok, envelope} <- writable(subject, actor, id) do
        revise(request, subject, actor, id, envelope, text)
      else
        :malformed ->
          {problem("malformed-request", "updatedPreference is required"), subject}

        :denied ->
          {problem("scope-denied", "Entry is outside the caller's scopes or does not exist"),
           subject}
      end
    end)
  end

  defp revise(request, subject, actor, id, envelope, text) do
    accepting = user?(actor) and status_of(envelope) == "conflicted"
    version = envelope["record"]["version"]

    next =
      envelope
      |> put_in(["claim", "subject", "preference"], text)
      |> put_in(["record", "version"], version + 1)
      |> put_in(["record", "previousVersion"], version)

    next =
      if accepting do
        next
        |> put_in(["record", "status"], "active")
        |> put_in(["record", "declarationType"], "user-declared")
        |> put_in(["record", "confidence"], nil)
      else
        next
      end

    reason = is_map(request.json) && request.json["reason"]

    subject =
      subject
      |> push_version(id, next)
      |> append(
        request,
        actor_event(actor, %{
          "eventType" => "preference.updated",
          "entryId" => id,
          "category" => category_of(next),
          "detail" => reason
        })
      )

    subject =
      if accepting do
        accept_conflict(subject, request, actor, next)
      else
        subject |> supersede(request, actor, next) |> detect_conflicts(request, id)
      end

    {ok(request, 200, redact(current(subject, id), actor, request)), subject}
  end

  defp delete(request, subject, actor, id) do
    hard = request.query["hardDelete"] == "true"

    idempotent(request, subject, "DELETE /v1/preferences/" <> id, fn subject ->
      case writable(subject, actor, id) do
        :denied ->
          {problem("scope-denied", "Entry is outside the caller's scopes or does not exist"),
           subject}

        {:ok, _envelope} when hard and actor.type != "user" ->
          {problem("scope-denied", "Hard deletion is the person's alone"), subject}

        {:ok, envelope} ->
          remove(request, subject, actor, id, envelope, hard)
      end
    end)
  end

  defp remove(request, subject, actor, id, envelope, hard) do
    rejecting = user?(actor) and status_of(envelope) == "conflicted"
    reason = request.query["reason"]

    subject =
      if hard do
        subject =
          if fault?(request, :hard_delete_keeps),
            do: subject,
            else: %{
              subject
              | entries: Map.delete(subject.entries, id),
                entry_order: List.delete(subject.entry_order, id)
            }

        append(
          subject,
          request,
          actor_event(actor, %{
            "eventType" => "preference.hardDeleted",
            "entryId" => id,
            "category" => category_of(envelope),
            "detail" => reason
          })
        )
      else
        subject
        |> put_current(id, put_in(envelope, ["record", "status"], "deleted"))
        |> append(
          request,
          actor_event(actor, %{
            "eventType" => "preference.deleted",
            "entryId" => id,
            "category" => category_of(envelope),
            "detail" => reason
          })
        )
      end

    subject =
      if rejecting do
        related = declared_counterpart(subject, envelope)

        append(
          subject,
          request,
          actor_event(actor, %{
            "eventType" => "conflict.resolved",
            "entryId" => id,
            "relatedEntryId" => related,
            "detail" => "rejected"
          })
        )
      else
        subject
      end

    {ok(request, 200, %{
       "entryId" => id,
       "status" => "deleted",
       "hardDeleted" => hard,
       "timestamp" => iso(request.now)
     }), subject}
  end

  # Conflicts (§2.6) ----------------------------------------------------------------

  defp normalize(nil), do: nil

  defp normalize(dimension),
    do: dimension |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "_")

  defp conflicting?(a, b) do
    category_of(a) == category_of(b) and normalize(a["record"]["dimension"]) != nil and
      normalize(a["record"]["dimension"]) == normalize(b["record"]["dimension"])
  end

  defp currents(subject), do: Enum.map(subject.entry_order, &current(subject, &1))

  defp detect_conflicts(subject, request, id) do
    entry = current(subject, id)

    if fault?(request, :no_conflicts) or status_of(entry) != "active",
      do: subject,
      else: quarantine_conflicts(subject, request, entry)
  end

  # §2.6: a new inference that contradicts a declaration is quarantined, and a new
  # declaration quarantines every inference it contradicts.
  defp quarantine_conflicts(subject, request, entry) do
    cond do
      inferred?(entry) ->
        case Enum.find(currents(subject), &(declared?(&1) and active_conflict?(&1, entry))) do
          nil -> subject
          declared -> quarantine(subject, request, entry, declared)
        end

      declared?(entry) ->
        currents(subject)
        |> Enum.filter(&(inferred?(&1) and active_conflict?(&1, entry)))
        |> Enum.reduce(subject, &quarantine(&2, request, &1, entry))

      true ->
        subject
    end
  end

  defp active_conflict?(candidate, entry),
    do: status_of(candidate) == "active" and conflicting?(candidate, entry)

  defp declared?(envelope), do: envelope["record"]["declarationType"] == "user-declared"
  defp inferred?(envelope), do: envelope["record"]["declarationType"] == "model-inferred"

  defp quarantine(subject, request, inferred, declared) do
    subject
    |> put_current(inferred["id"], put_in(inferred, ["record", "status"], "conflicted"))
    |> append(request, %{
      "eventType" => "conflict.detected",
      "actorId" => "system",
      "actorType" => "system",
      "entryId" => inferred["id"],
      "relatedEntryId" => declared["id"],
      "category" => category_of(inferred)
    })
  end

  defp declared_counterpart(subject, inferred) do
    case Enum.find(
           currents(subject),
           &(&1 != nil and declared?(&1) and active_conflict?(&1, inferred))
         ) do
      nil -> nil
      declared -> declared["id"]
    end
  end

  defp accept_conflict(subject, request, actor, accepted) do
    related =
      Enum.find(
        currents(subject),
        &(&1["id"] != accepted["id"] and declared?(&1) and status_of(&1) == "active" and
            conflicting?(&1, accepted))
      )

    subject =
      if related,
        do:
          put_current(subject, related["id"], put_in(related, ["record", "status"], "deprecated")),
        else: subject

    append(
      subject,
      request,
      actor_event(actor, %{
        "eventType" => "conflict.resolved",
        "entryId" => accepted["id"],
        "relatedEntryId" => related && related["id"],
        "detail" => "accepted"
      })
    )
  end

  defp supersede(subject, request, actor, revised) do
    if declared?(revised) do
      currents(subject)
      |> Enum.filter(
        &(inferred?(&1) and status_of(&1) == "conflicted" and
            category_of(&1) == category_of(revised))
      )
      |> Enum.reduce(subject, &release_if_unopposed(&2, request, actor, &1, revised))
    else
      subject
    end
  end

  # A quarantined inference returns to active once no active declaration
  # contradicts it.
  defp release_if_unopposed(subject, request, actor, inferred, revised) do
    if Enum.any?(currents(subject), &(declared?(&1) and active_conflict?(&1, inferred))) do
      subject
    else
      subject
      |> put_current(inferred["id"], put_in(inferred, ["record", "status"], "active"))
      |> append(
        request,
        actor_event(actor, %{
          "eventType" => "conflict.resolved",
          "entryId" => inferred["id"],
          "relatedEntryId" => revised["id"],
          "detail" => "superseded"
        })
      )
    end
  end

  # Grants --------------------------------------------------------------------------

  defp grant_object(grant) do
    %{
      "grantId" => grant.id,
      "client" => %{"id" => grant.client_id, "name" => grant.client_name},
      "scopes" => grant.scopes,
      "grantType" => grant.grant_type,
      "grantor" => nil,
      "issuedAt" => grant.issued_at,
      "expiresAt" => grant.expires_at,
      "status" => grant.status
    }
    |> then(fn object ->
      if grant.restrictions, do: Map.put(object, "restrictions", grant.restrictions), else: object
    end)
  end

  defp list_grants(request, subject, actor) do
    grants =
      if user?(actor) do
        status = request.query["status"] || "active"

        subject.grant_order
        |> Enum.map(&subject.grants[&1])
        |> Enum.filter(&(status == "all" or &1.status == status))
      else
        [actor.grant]
      end

    {ok(request, 200, %{"grants" => Enum.map(grants, &grant_object/1)}), subject}
  end

  defp revoke(request, subject, actor, id) do
    grant = subject.grants[id]

    cond do
      not user?(actor) ->
        {problem("scope-denied", "Revocation is the person's alone"), subject}

      is_nil(grant) ->
        {problem("scope-denied", "No such grant"), subject}

      true ->
        subject =
          if grant.status == "active" do
            subject
            |> put_in([:grants, id, :status], "revoked")
            |> append(
              request,
              actor_event(actor, %{"eventType" => "grant.revoked", "grantId" => id})
            )
          else
            subject
          end

        {ok(request, 200, %{
           "grantId" => id,
           "status" => "revoked",
           "timestamp" => iso(request.now)
         }), subject}
    end
  end

  # Audit and export -----------------------------------------------------------------

  defp public_event(event), do: Map.delete(event, "seq")

  defp audit(request, subject, actor) do
    limit = request.query["limit"]
    cursor = request.query["cursor"]

    with true <- user?(actor) || :denied,
         {:ok, limit} <- parse_limit(limit),
         {:ok, after_seq} <- parse_cursor(subject, cursor, request) do
      remaining = Enum.filter(subject.audit, &(&1["seq"] > after_seq))
      page = Enum.take(remaining, limit)
      more = length(remaining) > limit

      {next, subject} =
        if more do
          issue_cursor(subject, List.last(page)["seq"], request)
        else
          {nil, subject}
        end

      {ok(request, 200, %{"events" => Enum.map(page, &public_event/1), "nextCursor" => next}),
       subject}
    else
      :denied -> {problem("scope-denied", "The audit log is the person's alone"), subject}
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

    if not user?(actor) and not fault?(request, :export_open) do
      {problem("scope-denied", "Export is the person's alone"), subject}
    else
      ids =
        Enum.reject(subject.entry_order, fn id ->
          "deleted" in exclude and status_of(current(subject, id)) == "deleted"
        end)

      body = %{
        "entries" => Enum.map(ids, &current(subject, &1)),
        "exportedAt" => iso(request.now)
      }

      body =
        if "versions" in include,
          do:
            Map.put(
              body,
              "versions",
              Enum.map(
                ids,
                &%{"entryId" => &1, "versions" => Enum.reverse(subject.entries[&1].versions)}
              )
            ),
          else: body

      body =
        if "audit" in include,
          do: Map.put(body, "audit", Enum.map(subject.audit, &public_event/1)),
          else: body

      subject =
        append(
          subject,
          request,
          actor_event(actor, %{
            "eventType" => "preference.exported",
            "detail" => "include=#{Enum.join(include, ",")};exclude=#{Enum.join(exclude, ",")}"
          })
        )

      {ok(request, 200, body), subject}
    end
  end

  defp csv(nil), do: []
  defp csv(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # Idempotency (§3.4.3) -------------------------------------------------------------

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
    if bearer(request) != request.hook_secret do
      problem("invalid-token", "The conformance hook secret is missing or wrong")
    else
      hook_route(request, path, store)
    end
  end

  defp hook_route(%{method: "POST"}, ["subjects"], store) do
    id = String.replace_prefix(urn_uuid(), "urn:uuid:", "")
    token = "ref-person-" <> random_token()

    subject = %{
      id: id,
      did: "did:hcp:user:" <> id,
      person_token: token,
      entries: %{},
      entry_order: [],
      grants: %{},
      grant_order: [],
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
        nil -> {not_found("No such subject"), state}
        subject -> issue_grant(request, state, subject)
      end
    end)
  end

  defp hook_route(%{method: "DELETE"}, ["subjects", subject_id], store) do
    Store.transaction(store, fn state ->
      {{204, nil, nil, []}, Store.drop_subject(state, subject_id)}
    end)
  end

  defp hook_route(_request, _path, _store), do: not_found("No such hook route")

  defp grant_request_error(body, scopes, grant_type, seconds, restrictions) do
    cond do
      not non_empty_list?(scopes, &grant_scope?/1) ->
        "scopes must be hcp:{category}:{read|write} strings without wildcards"

      grant_type not in ["temporary", "persistent"] ->
        "grantType must be temporary or persistent"

      grant_type == "temporary" and not within_a_day?(seconds) ->
        "a temporary grant expires within 24 hours"

      not restrictions_held?(restrictions, scopes) ->
        "every restriction must reference a scope the grant holds"

      not (is_binary(body["clientId"]) and is_binary(body["clientName"])) ->
        "clientId and clientName are required"

      true ->
        nil
    end
  end

  defp grant_scope?(scope),
    do: is_binary(scope) and Regex.match?(~r/^hcp:[^*\s]+:(read|write)$/, scope)

  defp restrictions_held?(nil, _scopes), do: true

  defp restrictions_held?(restrictions, scopes) when is_list(restrictions),
    do: Enum.all?(restrictions, &(is_map(&1) and &1["scope"] in scopes))

  defp restrictions_held?(_restrictions, _scopes), do: false

  defp issue_grant(request, state, subject) do
    body = json_object(request)
    scopes = body["scopes"]
    grant_type = body["grantType"] || "temporary"
    seconds = body["expiresInSeconds"] || 3600
    restrictions = body["restrictions"]

    if error = grant_request_error(body, scopes, grant_type, seconds, restrictions) do
      {problem("malformed-request", error), state}
    else
      grant_id = urn_uuid()
      token = "ref-grant-" <> random_token()

      expires_at =
        if grant_type == "temporary", do: iso(DateTime.add(request.now, seconds, :second))

      grant = %{
        id: grant_id,
        client_id: body["clientId"],
        client_name: body["clientName"],
        scopes: scopes,
        restrictions: restrictions,
        grant_type: grant_type,
        issued_at: iso(request.now),
        expires_at: expires_at,
        status: "active"
      }

      detail =
        "grantType=#{grant_type}; expiresAt=#{expires_at || "none"}; modality=conformance-hook; scopes=#{Enum.join(scopes, " ")}" <>
          if(restrictions, do: "; restrictions=" <> Jason.encode!(restrictions), else: "")

      subject =
        %{
          subject
          | grants: Map.put(subject.grants, grant_id, grant),
            grant_order: subject.grant_order ++ [grant_id]
        }
        |> append(request, %{
          "eventType" => "grant.issued",
          "actorId" => subject.did,
          "actorType" => "user",
          "grantId" => grant_id,
          "detail" => detail
        })

      state = %{
        state
        | subjects: Map.put(state.subjects, subject.id, subject),
          tokens: Map.put(state.tokens, token, {subject.id, {:grant, grant_id}})
      }

      {{201, %{"grantId" => grant_id, "token" => token, "expiresAt" => expires_at},
        "application/json", []}, state}
    end
  end

  # Helpers ----------------------------------------------------------------------------

  defp iso(datetime), do: DateTime.to_iso8601(datetime)
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  # Its own generator rather than the checks': the reference shares no code with
  # the suite, so the two can never share a bug.
  defp urn_uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "urn:uuid:#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end
end
