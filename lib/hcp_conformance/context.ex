defmodule HcpConformance.Context do
  @moduledoc """
  Everything a check needs about the target, set up once per run: the discovery
  document and the endpoints it names, the credentials (from the hook or
  supplied), the categories to work in, and a per-run nonce so checks can find
  their own entries in a subject that holds other data.

  Mutable run state (the transcript, entries to clean up) lives in processes the
  context points at, so the struct can be handed to checks running in tasks.
  """

  alias HcpConformance.{Assert, Config, Hook, HTTP, Transcript}

  @registered_categories ~w(general_preferences goals_and_constraints health_context education_learner_profile
                            work_context purchase_history_preferences values_and_ethics location_context
                            coordination_context)

  defstruct [
    :config,
    :transcript,
    :state,
    :discovery,
    :discovery_response,
    :endpoints,
    :person_token,
    :subject_did,
    :subject_id,
    :agent,
    :primary_category,
    :outside_category,
    :second_category,
    :envelope_form,
    :read_window_ms,
    :nonce,
    capabilities: MapSet.new(),
    setup_notes: []
  ]

  @type t :: %__MODULE__{}

  @doc "The registered category vocabulary (§2.5)."
  @spec registered_categories() :: [String.t()]
  def registered_categories, do: @registered_categories

  @doc "Sets up a run. Never raises: problems become setup notes and missing capabilities."
  @spec start(Config.t()) :: t()
  def start(%Config{} = config) do
    {:ok, transcript} = Transcript.start_link()
    {:ok, state} = Agent.start_link(fn -> %{entries: [], grants: []} end)

    Enum.each(
      [config.hook_secret, config.person_token, config.agent_token],
      &Transcript.add_secret(transcript, &1)
    )

    %__MODULE__{config: config, transcript: transcript, state: state, nonce: random_word(10)}
    |> load_discovery()
    |> resolve_endpoints()
    |> choose_categories()
    |> authenticate()
  end

  @doc "Releases the run: hard-deletes entries the suite created, or disposes of the hook subject."
  @spec finish(t()) :: :ok
  def finish(%__MODULE__{} = ctx) do
    Process.put(:hcp_check_id, "teardown")

    try do
      case Config.mode(ctx.config) do
        :hook when is_binary(ctx.subject_id) ->
          Hook.delete_subject(
            ctx.transcript,
            ctx.config.allow_private,
            ctx.config.hook_url,
            ctx.config.hook_secret,
            ctx.subject_id
          )

        _other when is_binary(ctx.person_token) ->
          for id <- Agent.get(ctx.state, & &1.entries) do
            request(ctx, :delete, entry_url(ctx, id),
              token: ctx.person_token,
              params: [hardDelete: true, reason: "conformance cleanup"]
            )
          end

        _other ->
          :ok
      end
    rescue
      _error -> :ok
    end

    :ok
  end

  @doc "Sends a request to the target, through the run's transcript and guard."
  @spec request(t(), atom(), String.t(), HTTP.opts()) :: HTTP.Response.t()
  def request(%__MODULE__{} = ctx, method, url, opts \\ []) do
    HTTP.request(ctx.transcript, ctx.config.allow_private, method, url, opts)
  end

  @doc "A URL for a named endpoint."
  @spec url(t(), atom()) :: String.t()
  def url(ctx, name), do: Map.fetch!(ctx.endpoints, name)

  @spec entry_url(t(), String.t()) :: String.t()
  def entry_url(ctx, id), do: ctx.endpoints.preferences <> "/" <> segment(id)

  @spec grant_url(t(), String.t()) :: String.t()
  def grant_url(ctx, id), do: ctx.endpoints.grants <> "/" <> segment(id)

  # Ids are urn:uuid values. A colon is legal in a path segment (RFC 3986
  # pchar), and some servers do not decode %3A, so it is sent as-is.
  defp segment(id), do: URI.encode(id, &(URI.char_unreserved?(&1) or &1 == ?:))

  @doc "The person's token, or skip."
  @spec person!(t()) :: String.t()
  def person!(%__MODULE__{person_token: nil}),
    do: Assert.skip!("no person credential for this run")

  def person!(%__MODULE__{person_token: token}), do: token

  @doc "The default agent (read and write on the primary category), or skip."
  @spec agent!(t()) :: map()
  def agent!(%__MODULE__{agent: nil}),
    do: Assert.skip!("no agent credential with read and write on the primary category")

  def agent!(%__MODULE__{agent: agent}), do: agent

  @doc "Whether the run has a capability."
  @spec has?(t(), atom()) :: boolean()
  def has?(ctx, capability), do: MapSet.member?(ctx.capabilities, capability)

  @doc """
  Issues a grant through the hook, as the subject's own act. `opts`: `:scopes`
  (required), `:grant_type` ("temporary"), `:expires_in` (seconds, 3600),
  `:restrictions`, `:client_name`. Skips when the run has no hook.
  """
  @spec issue_grant!(t(), keyword()) :: map()
  def issue_grant!(ctx, opts) do
    case issue_grant(ctx, opts) do
      {:ok, grant} ->
        grant

      {:error, message} ->
        Assert.fail!("the conformance hook could not issue a grant: " <> message)
    end
  end

  @doc "Like `issue_grant!/2`, but returns `{:error, message}` when the hook refuses."
  @spec issue_grant(t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def issue_grant(ctx, opts) do
    if not has?(ctx, :hook), do: Assert.skip!("needs the conformance hook to issue grants")
    client_id = "hcp-conformance-" <> random_word(8)
    grant_type = Keyword.get(opts, :grant_type, "temporary")

    attrs =
      %{
        "clientId" => client_id,
        "clientName" => Keyword.get(opts, :client_name, "HCP conformance client " <> client_id),
        "actorType" => "agent",
        "scopes" => Keyword.fetch!(opts, :scopes),
        "grantType" => grant_type
      }
      |> put_if(
        grant_type == "temporary",
        "expiresInSeconds",
        Keyword.get(opts, :expires_in, 3600)
      )
      |> put_if(Keyword.has_key?(opts, :restrictions), "restrictions", opts[:restrictions])

    case Hook.issue_grant(
           ctx.transcript,
           ctx.config.allow_private,
           ctx.config.hook_url,
           ctx.config.hook_secret,
           ctx.subject_id,
           attrs
         ) do
      {:ok, grant} ->
        Transcript.add_secret(ctx.transcript, grant.token)
        Agent.update(ctx.state, &%{&1 | grants: [grant.grant_id | &1.grants]})
        {:ok, Map.put(grant, :scopes, attrs["scopes"])}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Remembers an entry the suite created, for cleanup in static mode."
  @spec track_entry(t(), String.t()) :: :ok
  def track_entry(ctx, id), do: Agent.update(ctx.state, &%{&1 | entries: [id | &1.entries]})

  @doc "A fresh lowercase word unique to this run, for finding the suite's own entries by search."
  @spec unique_word(t()) :: String.t()
  def unique_word(ctx), do: "hcpc" <> ctx.nonce <> random_word(6)

  @doc "A random lowercase word: letters only, so every tokenizer keeps it whole."
  @spec random_word(pos_integer()) :: String.t()
  def random_word(length) do
    for _ <- 1..length, into: "", do: <<Enum.random(?a..?z)>>
  end

  defp load_discovery(ctx) do
    url = ctx.config.discovery_url || ctx.config.target <> "/.well-known/hcp-configuration"
    Process.put(:hcp_check_id, "setup")

    try do
      response = request(ctx, :get, url)
      discovery = if response.status == 200 and is_map(response.json), do: response.json

      note =
        if discovery, do: [], else: ["discovery document not usable (HTTP #{response.status})"]

      %{
        ctx
        | discovery: discovery,
          discovery_response: response,
          setup_notes: ctx.setup_notes ++ note
      }
    rescue
      error in HTTP.TransportError ->
        %{ctx | setup_notes: ctx.setup_notes ++ ["discovery request failed: " <> error.message]}
    end
  end

  defp resolve_endpoints(ctx) do
    discovery = ctx.discovery || %{}
    base = ctx.config.target
    preferences = string_or(discovery["preferences_endpoint"], base <> "/v1/preferences")
    transports = discovery["supported_transports"]
    rest? = not is_list(transports) or "rest" in transports
    mcp? = is_list(transports) and "mcp" in transports

    endpoints = %{
      discovery: ctx.config.discovery_url || base <> "/.well-known/hcp-configuration",
      preferences: preferences,
      search: preferences <> "/search",
      grants: string_or(discovery["grants_endpoint"], base <> "/v1/grants"),
      audit: string_or(discovery["audit_endpoint"], base <> "/v1/audit"),
      export: string_or(discovery["export_endpoint"], base <> "/v1/export"),
      mcp_manifest: discovery["mcp_manifest_endpoint"]
    }

    window =
      case get_in(discovery, ["audit_durability", "bounded", "preference.read"]) do
        ms when is_integer(ms) and ms >= 0 -> ms
        _other -> 0
      end

    capabilities =
      ctx.capabilities
      |> put_capability(rest?, :rest)
      |> put_capability(mcp?, :mcp)

    %{
      ctx
      | endpoints: endpoints,
        capabilities: capabilities,
        envelope_form: if(discovery["envelope_form"] == "flat", do: "flat", else: "grouped"),
        read_window_ms: window
    }
  end

  defp choose_categories(ctx) do
    supported =
      case ctx.discovery && ctx.discovery["supported_categories"] do
        list when is_list(list) and list != [] -> Enum.filter(list, &is_binary/1)
        _other -> @registered_categories
      end

    primary = ctx.config.category || hd(supported ++ ["general_preferences"])
    second = Enum.find(supported, &(&1 != primary))
    outside = Enum.find(@registered_categories, &(&1 != primary))

    %{
      ctx
      | primary_category: primary,
        second_category: second,
        outside_category: outside,
        capabilities: put_capability(ctx.capabilities, second != nil, :second_category)
    }
  end

  defp authenticate(ctx) do
    case Config.mode(ctx.config) do
      :hook -> authenticate_hook(ctx)
      :static -> authenticate_static(ctx)
      :anonymous -> ctx
    end
  end

  defp authenticate_hook(ctx) do
    config = ctx.config

    case Hook.create_subject(
           ctx.transcript,
           config.allow_private,
           config.hook_url,
           config.hook_secret
         ) do
      {:ok, subject} ->
        Transcript.add_secret(ctx.transcript, subject.person_token)

        ctx = %{
          ctx
          | subject_id: subject.subject_id,
            subject_did: subject.subject_did || config.subject_did || "did:hcp:user:conformance",
            person_token: subject.person_token,
            capabilities: ctx.capabilities |> MapSet.put(:person) |> MapSet.put(:hook)
        }

        try do
          grant = issue_grant!(ctx, scopes: scopes(ctx.primary_category, ["read", "write"]))
          agent = Map.put(grant, :scopes, scopes(ctx.primary_category, ["read", "write"]))
          %{ctx | agent: agent, capabilities: MapSet.put(ctx.capabilities, :agent)}
        rescue
          error in [HcpConformance.Failure, HTTP.TransportError] ->
            %{
              ctx
              | setup_notes:
                  ctx.setup_notes ++ ["default agent grant: " <> Exception.message(error)]
            }
        end

      {:error, message} ->
        %{ctx | setup_notes: ctx.setup_notes ++ ["conformance hook: " <> message]}
    end
  rescue
    error in HTTP.TransportError ->
      %{ctx | setup_notes: ctx.setup_notes ++ ["conformance hook: " <> error.message]}
  end

  defp authenticate_static(ctx) do
    ctx = %{
      ctx
      | person_token: ctx.config.person_token,
        subject_did: ctx.config.subject_did || "did:hcp:user:conformance",
        capabilities: MapSet.put(ctx.capabilities, :person)
    }

    case ctx.config.agent_token do
      nil -> ctx
      token -> describe_static_agent(ctx, token)
    end
  end

  # A supplied agent token says nothing about its grant; the grants endpoint
  # tells a client its own grant (§4.1.5), which is enough to know its scopes.
  defp describe_static_agent(ctx, token) do
    response = request(ctx, :get, ctx.endpoints.grants, token: token)

    with %{status: 200, json: %{"grants" => [grant | _]}} <- response,
         scopes when is_list(scopes) <- grant["scopes"],
         true <- Enum.all?(scopes(ctx.primary_category, ["read", "write"]), &(&1 in scopes)) do
      agent = %{
        token: token,
        grant_id: grant["grantId"],
        client_id: get_in(grant, ["client", "id"]),
        scopes: scopes
      }

      %{ctx | agent: agent, capabilities: MapSet.put(ctx.capabilities, :agent)}
    else
      _other ->
        note =
          "agent token supplied, but its grant could not be read or lacks read and write on #{ctx.primary_category}"

        %{ctx | setup_notes: ctx.setup_notes ++ [note]}
    end
  rescue
    error in HTTP.TransportError ->
      %{ctx | setup_notes: ctx.setup_notes ++ ["agent token: " <> error.message]}
  end

  @doc "Scope strings for a category and actions (§4.1.1)."
  @spec scopes(String.t(), [String.t()]) :: [String.t()]
  def scopes(category, actions), do: Enum.map(actions, &"hcp:#{category}:#{&1}")

  defp put_capability(set, true, capability), do: MapSet.put(set, capability)
  defp put_capability(set, _false, _capability), do: set

  defp string_or(value, _default) when is_binary(value) and value != "",
    do: String.trim_trailing(value, "/")

  defp string_or(_value, default), do: default

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, _false, _key, _value), do: map
end
