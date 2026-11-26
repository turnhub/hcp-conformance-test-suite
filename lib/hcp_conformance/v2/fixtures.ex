defmodule HcpConformance.V2.Fixtures do
  @moduledoc """
  Entries the suite writes to a v2 target, and the requests most checks share.
  Every statement carries a word unique to the run, so a query for that word
  finds exactly the entries a check wrote.

  A Management Client (the person's token) names an entry by its `id` and
  receives entries whole; a Context Client (a grant's token) names it by the
  `ref` it was disclosed with and receives disclosures (§7.4). `handle/1` reads
  whichever the caller was given.
  """

  alias HcpConformance.{Assert, Context, V2.Target}

  @entry_schema "https://hcp.example/spec/entry/2.0"
  @general_context "https://hcp.example/spec/profiles/general-context/2.0"

  @spec entry_schema() :: String.t()
  def entry_schema, do: @entry_schema

  @spec general_context() :: String.t()
  def general_context, do: @general_context

  @doc """
  The body of a create (§5.2.3). `opts`: `:value`, `:categories`, `:dimension`,
  `:declaration_type` ("person-declared"), `:confidence`, `:asserted_by`,
  `:merge` (a map deep-merged over the body, for forged or extra members) and
  `:drop` (paths to remove, for negative tests).
  """
  @spec entry_body(Context.t(), keyword()) :: map()
  def entry_body(ctx, opts \\ []) do
    declaration = Keyword.get(opts, :declaration_type, "person-declared")

    assertion =
      %{"declarationType" => declaration}
      |> put_some("confidence", Keyword.get(opts, :confidence))

    provenance =
      %{"source" => "conversation-id:hcp-conformance-" <> ctx.nonce}
      |> put_some("assertedBy", opts[:asserted_by] && %{"id" => opts[:asserted_by]})

    body = %{
      "schema" => @entry_schema,
      "subject" => %{"id" => ctx.subject_did},
      "content" => %{
        "profile" => @general_context,
        "value" =>
          Keyword.get(opts, :value, "Conformance statement " <> Context.unique_word(ctx)),
        "language" => "en"
      },
      "assertion" => assertion,
      "classification" =>
        %{"categories" => Keyword.get(opts, :categories, [ctx.primary_category])}
        |> put_some("dimension", opts[:dimension]),
      "record" => %{"provenance" => provenance}
    }

    body = deep_merge(body, Keyword.get(opts, :merge, %{}))
    Enum.reduce(Keyword.get(opts, :drop, []), body, &drop_path(&2, &1))
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = a, %{} = b -> deep_merge(a, b)
      _key, _a, b -> b
    end)
  end

  defp drop_path(body, path) do
    {_dropped, rest} = pop_in(body, path)
    rest
  end

  @doc "Sends a create and returns the response."
  @spec post(Context.t(), String.t(), map(), keyword()) :: HcpConformance.HTTP.Response.t()
  def post(ctx, token, body, opts \\ []) do
    Context.request(ctx, :post, Context.url(ctx, :entries), [token: token, json: body] ++ opts)
  end

  @doc "Creates an entry and returns the 201 body: the entry, or a disclosure for a Context Client."
  @spec create!(Context.t(), String.t(), keyword()) :: map()
  def create!(ctx, token, opts \\ []) do
    response = post(ctx, token, entry_body(ctx, opts))
    Assert.status!(response, 201, "POST /v2/entries")
    created = Assert.json_object!(response, "POST /v2/entries")

    Assert.check!(
      is_binary(handle(created)),
      "POST /v2/entries: the result carries neither an id nor a ref"
    )

    if is_binary(created["id"]), do: Context.track_entry(ctx, created["id"])
    created
  end

  @doc "What the caller names an entry by: its `id`, or the `ref` of a disclosure."
  @spec handle(map()) :: String.t() | nil
  def handle(%{"id" => id}) when is_binary(id), do: id
  def handle(%{"ref" => ref}) when is_binary(ref), do: ref
  def handle(_other), do: nil

  @doc "Queries as `token`; returns the response."
  @spec query(Context.t(), String.t(), map()) :: HcpConformance.HTTP.Response.t()
  def query(ctx, token, body) do
    body =
      Map.merge(%{"categories" => [ctx.primary_category], "purpose" => Target.purpose()}, body)

    Context.request(ctx, :post, Context.url(ctx, :query), token: token, json: body)
  end

  @doc "Queries as `token` and returns the 200 body."
  @spec query!(Context.t(), String.t(), map()) :: map()
  def query!(ctx, token, body) do
    response = query(ctx, token, body)
    Assert.status!(response, 200, "POST /v2/entries/query")
    result = Assert.json_object!(response, "POST /v2/entries/query")
    Assert.check!(is_list(result["entries"]), "POST /v2/entries/query: no entries array")
    result
  end

  @doc "Reads one entry as `token`; returns the response."
  @spec get(Context.t(), String.t(), String.t(), keyword()) :: HcpConformance.HTTP.Response.t()
  def get(ctx, token, handle, params \\ []) do
    Context.request(ctx, :get, Context.entry_url(ctx, handle),
      token: token,
      params: Keyword.merge([purpose: Target.purpose()], params)
    )
  end

  @doc "Reads one entry as `token` and returns the `entry` of the 200 result."
  @spec get!(Context.t(), String.t(), String.t(), keyword()) :: map()
  def get!(ctx, token, handle, params \\ []) do
    response = get(ctx, token, handle, params)
    Assert.status!(response, 200, "GET /v2/entries/{entryId}")
    entry = Assert.json_object!(response, "GET /v2/entries/{entryId}")["entry"]
    Assert.check!(is_map(entry), "GET /v2/entries/{entryId}: the result has no entry")
    entry
  end

  @doc "Sends a revision of the entry `handle` names; returns the response."
  @spec revise(Context.t(), String.t(), String.t(), map(), keyword()) ::
          HcpConformance.HTTP.Response.t()
  def revise(ctx, token, handle, body, opts \\ []) do
    body =
      Map.merge(
        %{
          "content" => %{
            "profile" => @general_context,
            "value" => "Revised conformance statement " <> Context.unique_word(ctx)
          },
          "reason" => "HCP conformance check"
        },
        body
      )

    Context.request(
      ctx,
      :post,
      Context.entry_url(ctx, handle) <> "/revisions",
      [token: token, json: body] ++ opts
    )
  end

  @doc "Withdraws, or with `hardDelete: true` hard-deletes, the entry; returns the response."
  @spec delete(Context.t(), String.t(), String.t(), keyword()) :: HcpConformance.HTTP.Response.t()
  def delete(ctx, token, handle, opts \\ []) do
    {params, opts} = Keyword.pop(opts, :params, [])

    Context.request(
      ctx,
      :delete,
      Context.entry_url(ctx, handle),
      [token: token, params: Keyword.merge([reason: "HCP conformance check"], params)] ++ opts
    )
  end

  @doc "The disclosures a Context Client's query for `word` returns."
  @spec found(Context.t(), String.t(), String.t()) :: [map()]
  def found(ctx, token, word),
    do: query!(ctx, token, %{"query" => word, "maxEntries" => 20})["entries"]

  @doc "The statements in a query result or an export, for telling the suite's entries apart."
  @spec values(map()) :: [term()]
  def values(%{"entries" => entries}) when is_list(entries),
    do: Enum.map(entries, &(is_map(&1) && get_in(&1, ["content", "value"])))

  def values(_body), do: []

  @doc "Whether a string is an RFC 3339 date-time (§1.10)."
  @spec date_time?(term()) :: boolean()
  def date_time?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  def date_time?(_value), do: false

  @doc "Whether a string is a `urn:uuid:` identifier."
  @spec urn_uuid?(term()) :: boolean()
  def urn_uuid?(value) when is_binary(value),
    do:
      Regex.match?(
        ~r/^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
        value
      )

  def urn_uuid?(_value), do: false
end
