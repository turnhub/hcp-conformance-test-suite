defmodule HcpConformance.Vault do
  @moduledoc """
  The person's HCP vault, as the chat page demonstrates it: memories that belong
  to the person, and assistants that read them only through grants the person
  issues, can narrow, and can revoke.

  Nothing is implicit. Connecting creates a subject (through the conformance
  hook) and issues no grant at all; every grant is an explicit `issue_grant/3`,
  standing in for the vault's own consent screen. The person's side (listing and
  revoking grants, the audit log, export, every memory with its status) uses the
  person's credential; an assistant's side (`recall/4`, `remember/3` with its
  token) uses the grant's token, so the vault enforces the grant, not this page.

  It reuses the suite's run context: discovery, endpoints, the private-network
  guard, and a transcript that redacts every credential, so `traced/2` can show
  each operation's HTTP exchanges.
  """

  alias HcpConformance.{Config, Context, Fixtures, HTTP, Transcript}

  @enforce_keys [:context]
  defstruct [:context]

  @type t :: %__MODULE__{context: Context.t()}
  @type assistant :: %{:id => String.t(), :name => String.t(), optional(atom()) => term()}
  @type grant :: %{:token => String.t(), :scopes => [String.t()], optional(atom()) => term()}
  @type author :: :person | String.t()
  @type refusal :: %{status: pos_integer() | nil, type: String.t(), detail: String.t()}

  @default_purpose "Answer the person's message"

  @doc "Connects as the person. With the hook, a fresh subject; no grant is issued."
  @spec connect(Config.t()) :: {:ok, t()} | {:error, String.t()}
  def connect(%Config{} = config) do
    case Context.start(config, default_grant: false) do
      %Context{person_token: token} = context when is_binary(token) ->
        {:ok, %__MODULE__{context: context}}

      context ->
        close(%__MODULE__{context: context})
        {:error, "cannot act as the person on this target: " <> why_not(context)}
    end
  end

  @doc """
  Ties the connection to the calling process (the chat page), so its helper
  processes stop with it rather than with the task that connected.
  """
  @spec link(t()) :: :ok
  def link(%__MODULE__{context: context}) do
    Process.link(context.transcript)
    Process.link(context.state)
    :ok
  end

  @doc "Disposes of the hook subject, if any, and stops the connection's processes."
  @spec close(t()) :: :ok
  def close(%__MODULE__{context: context}) do
    Context.finish(context)
    Enum.each([context.transcript, context.state], &stop/1)
  end

  @doc "Whether grants can be issued here: only through the conformance hook."
  @spec can_issue?(t()) :: boolean()
  def can_issue?(%__MODULE__{context: context}), do: Context.has?(context, :hook)

  @doc "The categories the vault supports, from its discovery document."
  @spec categories(t()) :: [String.t()]
  def categories(%__MODULE__{context: %{discovery: %{"supported_categories" => categories}}})
      when is_list(categories) and categories != [],
      do: categories

  def categories(%__MODULE__{context: context}), do: [context.primary_category]

  @doc """
  Runs `operation` and returns its result with the HTTP exchanges it made,
  redacted and ready to show. Each trace tags its requests, so traces running
  at the same time (a reply while a memory is saved) never mix.
  """
  @spec traced(t(), (-> result)) :: {result, [map()]} when result: term()
  def traced(%__MODULE__{context: context}, operation) do
    tag = "trace-" <> Integer.to_string(System.unique_integer([:positive]))
    previous = Process.put(:hcp_check_id, tag)

    result =
      try do
        operation.()
      after
        restore(previous)
      end

    exchanges =
      for exchange <- Transcript.exchanges(context.transcript),
          exchange.check_id == tag,
          do: Transcript.serializable(exchange)

    {result, exchanges}
  end

  defp restore(nil), do: Process.delete(:hcp_check_id)
  defp restore(previous), do: Process.put(:hcp_check_id, previous)

  # The person's side -----------------------------------------------------------------

  @doc """
  The person grants `assistant` access, as the vault's consent screen would.
  `attrs`: `categories`, `actions` (`"read"`, `"write"`), `grant_type`
  (`"temporary"` or `"persistent"`), `expires_in` (seconds, temporary only) and
  `restrict_to` (entry ids that reads are narrowed to, §4.1.5.1).
  """
  @spec issue_grant(t(), assistant(), map()) :: {:ok, map()} | {:error, String.t()}
  def issue_grant(%__MODULE__{context: context}, %{id: id, name: name}, attrs) do
    scopes =
      for category <- attrs.categories, action <- attrs.actions, do: "hcp:#{category}:#{action}"

    opts =
      [
        scopes: scopes,
        grant_type: attrs.grant_type,
        expires_in: attrs[:expires_in] || 3600,
        client_id: "#{id}-#{context.nonce}",
        client_name: name
      ]
      |> with_restrictions(scopes, attrs[:restrict_to])

    Context.issue_grant(context, opts)
  rescue
    error in [HTTP.TransportError, HcpConformance.Skip] -> {:error, Exception.message(error)}
  end

  defp with_restrictions(opts, _scopes, ids) when ids in [nil, []], do: opts

  defp with_restrictions(opts, scopes, ids) do
    restrictions =
      for scope <- scopes,
          String.ends_with?(scope, ":read"),
          do: %{"scope" => scope, "narrowedTo" => %{"entryIds" => ids}}

    Keyword.put(opts, :restrictions, restrictions)
  end

  @doc "Every grant the person has issued, whatever its status (§4.1.5)."
  @spec grants(t()) :: {:ok, [map()]} | {:error, refusal()}
  def grants(%__MODULE__{context: context}) do
    context
    |> as_person(:get, Context.url(context, :grants), params: [status: "all"])
    |> expect(200, fn %{"grants" => grants} -> grants end)
  end

  @doc "The person revokes a grant; the assistant's next request is refused."
  @spec revoke(t(), String.t()) :: :ok | {:error, refusal()}
  def revoke(%__MODULE__{context: context}, grant_id) do
    response = as_person(context, :delete, Context.grant_url(context, grant_id))
    with {:ok, _body} <- expect(response, 200, & &1), do: :ok
  end

  @doc "Every memory in the vault with its status, through the person's export (§4.3.5)."
  @spec entries(t()) :: {:ok, [map()]} | {:error, refusal()}
  def entries(%__MODULE__{context: context}) do
    context
    |> as_person(:get, Context.url(context, :export))
    |> expect(200, fn %{"entries" => entries} -> entries end)
  end

  @doc "The person's export, as the JSON the vault returned."
  @spec export(t()) :: {:ok, String.t()} | {:error, refusal()}
  def export(%__MODULE__{context: context}) do
    response = as_person(context, :get, Context.url(context, :export))
    with {:ok, _body} <- expect(response, 200, & &1), do: {:ok, response.body}
  end

  @doc "The person's audit log, newest first (§4.3)."
  @spec audit(t()) :: {:ok, [map()]} | {:error, refusal()}
  def audit(%__MODULE__{context: context}), do: audit_pages(context, nil, [], 5)

  defp audit_pages(context, cursor, events, pages_left) do
    params = if cursor, do: [limit: 200, cursor: cursor], else: [limit: 200]

    case as_person(context, :get, Context.url(context, :audit), params: params) do
      %{status: 200, json: %{"events" => page, "nextCursor" => next}}
      when is_binary(next) and pages_left > 1 ->
        audit_pages(context, next, events ++ page, pages_left - 1)

      %{status: 200, json: %{"events" => page}} ->
        {:ok, Enum.reverse(events ++ page)}

      response ->
        {:error, refusal(response)}
    end
  rescue
    error in HTTP.TransportError -> {:error, transport(error)}
  end

  # Either side ------------------------------------------------------------------------

  @doc """
  Saves a memory, written by the person (`:person`) or by an assistant (its
  grant token, which needs write on the category). `attrs`: `text`, `category`,
  and optionally `dimension`, `declaration_type`, `confidence`.
  """
  @spec remember(t(), author(), map()) :: {:ok, map()} | {:error, refusal()}
  def remember(%__MODULE__{context: context}, author, attrs) do
    body =
      Fixtures.entry_body(context,
        preference: attrs.text,
        category: attrs.category,
        dimension: blank_to_nil(attrs[:dimension]),
        declaration_type: attrs[:declaration_type] || "user-declared",
        confidence: blank_to_nil(attrs[:confidence])
      )

    context
    |> Context.request(:post, Context.url(context, :preferences),
      token: token(context, author),
      json: body
    )
    |> expect(201, & &1)
  rescue
    error in HTTP.TransportError -> {:error, transport(error)}
  end

  # The assistant's side ---------------------------------------------------------------

  @doc """
  The memories `query` touches, read with an assistant's `grant` (its token and
  scopes). The vault decides what the grant may see. `opts`: `categories`
  (default: those the grant can read; others are refused), `max_entries` (5),
  `detail` (`"full"` or `"minimal"`) and `purpose`.
  """
  @spec recall(t(), grant(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, refusal()}
  def recall(%__MODULE__{context: context}, %{token: token, scopes: _} = grant, query, opts \\ []) do
    body = %{
      "categories" => opts[:categories] || readable(grant),
      "purpose" => opts[:purpose] || @default_purpose,
      "query" => query,
      "maxEntries" => opts[:max_entries] || 5,
      "responseDetail" => opts[:detail] || "full"
    }

    context
    |> Context.request(:post, Context.url(context, :search), token: token, json: body)
    |> expect(200, fn %{"entries" => entries} -> entries end)
  rescue
    error in HTTP.TransportError -> {:error, transport(error)}
  end

  @doc "The categories a grant's scopes let it read."
  @spec readable(grant()) :: [String.t()]
  def readable(%{scopes: scopes}) do
    for "hcp:" <> scope <- scopes,
        String.ends_with?(scope, ":read"),
        do: String.replace_suffix(scope, ":read", "")
  end

  @doc """
  The instructions an assistant gets: the recalled memories, where they came
  from, and how to use them. With none, it is told so, so it does not guess.
  """
  @spec instructions(String.t(), [map()]) :: String.t()
  def instructions(assistant_name, []) do
    """
    You are #{assistant_name}. No memories from the user's HCP vault were shared for \
    this message. Answer without assuming anything about the user.
    """
  end

  def instructions(assistant_name, entries) do
    memories =
      Enum.map_join(entries, "\n", &"- #{preference(&1)} (#{category(&1)}, #{declaration(&1)})")

    """
    You are #{assistant_name}. The user keeps their memories in their own HCP vault \
    (Human Context Protocol), not with you. These were retrieved from it for this \
    message, through a grant the user issued:

    #{memories}

    Use them where they help, and say when you rely on one. Do not invent others.
    """
  end

  # Reading an entry, in either envelope form (§2.2.1) ------------------------------------

  @doc "A memory's statement."
  @spec preference(map()) :: String.t()
  def preference(entry), do: entry |> field(["claim", "subject", "preference"]) |> text()

  @doc "A memory's category."
  @spec category(map()) :: String.t() | nil
  def category(entry), do: field(entry, ["record", "category"])

  @doc "A memory's dimension, if any."
  @spec dimension(map()) :: String.t() | nil
  def dimension(entry), do: field(entry, ["record", "dimension"])

  @doc "How a memory was declared: user-declared, model-inferred or issuer-attested."
  @spec declaration(map()) :: String.t() | nil
  def declaration(entry), do: field(entry, ["record", "declarationType"])

  @doc "A model-inferred memory's confidence."
  @spec confidence(map()) :: String.t() | nil
  def confidence(entry), do: field(entry, ["record", "confidence"])

  @doc "A memory's status: active, conflicted or deleted (§2.6)."
  @spec status(map()) :: String.t() | nil
  def status(entry), do: field(entry, ["record", "status"])

  defp field(entry, [group | rest] = path) do
    case get_in(entry, path) do
      nil when group in ["claim", "record"] -> get_in(entry, rest)
      value -> value
    end
  end

  # Helpers ------------------------------------------------------------------------------

  defp as_person(context, method, url, opts \\ []),
    do: Context.request(context, method, url, Keyword.put(opts, :token, context.person_token))

  defp token(context, :person), do: context.person_token
  defp token(_context, token) when is_binary(token), do: token

  defp expect(%{status: status, json: json}, status, take) when is_map(json),
    do: {:ok, take.(json)}

  defp expect(response, _status, _take), do: {:error, refusal(response)}

  # A refusal as the vault put it: the problem type's last segment and its detail.
  defp refusal(%{status: status, json: %{"type" => type} = problem}) when is_binary(type),
    do: %{
      status: status,
      type: type |> String.split("/") |> List.last(),
      detail: problem["detail"] || ""
    }

  defp refusal(%{status: status, body: body}),
    do: %{status: status, type: "unexpected-response", detail: Transcript.excerpt(body, 300)}

  defp transport(error),
    do: %{status: nil, type: "transport-error", detail: Exception.message(error)}

  defp why_not(%Context{setup_notes: []}),
    do: "connect with a conformance hook, or with a person token"

  defp why_not(%Context{setup_notes: notes}), do: Enum.join(notes, "; ")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp text(preference) when is_binary(preference), do: preference
  defp text(nil), do: ""
  defp text(preference), do: Jason.encode!(preference)

  defp stop(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
