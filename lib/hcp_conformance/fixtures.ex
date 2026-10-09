defmodule HcpConformance.Fixtures do
  @moduledoc """
  Entries the suite writes. Every preference statement carries a word unique to
  the run (and usually to the check), so a search for that word finds exactly the
  entries the check wrote, even in a subject that already holds data.
  """

  alias HcpConformance.{Assert, Context}

  @doc """
  The body of `POST /v1/preferences` (§3.3.2): an HCPEntry without the
  server-assigned fields, in the envelope form the target declared.

  `opts`: `:preference`, `:category`, `:dimension`, `:declaration_type`
  ("user-declared"), `:confidence`, `:user_verified`, `:drop` (grouped paths to
  remove, for negative tests).
  """
  @spec entry_body(Context.t(), keyword()) :: map()
  def entry_body(ctx, opts \\ []) do
    declaration = Keyword.get(opts, :declaration_type, "user-declared")
    confidence = Keyword.get(opts, :confidence, if(declaration == "model-inferred", do: "medium"))

    claim =
      compact(%{
        "issuer" => %{"id" => "did:web:conformance.hcp.example", "type" => "HCPSource"},
        "expirationDate" => nil,
        "subject" => %{
          "id" => ctx.subject_did,
          "preference" =>
            Keyword.get(opts, :preference, "Conformance statement " <> Context.unique_word(ctx))
        }
      })

    record =
      compact(%{
        "category" => Keyword.get(opts, :category, ctx.primary_category),
        "dimension" => Keyword.get(opts, :dimension),
        "declarationType" => declaration,
        "confidence" => confidence,
        "provenance" => %{
          "source" => "conversation-id:hcp-conformance-" <> ctx.nonce,
          "capturedAt" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "capturedBy" => "agent:hcp-conformance-suite",
          "userVerified" => Keyword.get(opts, :user_verified, declaration == "user-declared")
        }
      })

    body =
      case ctx.envelope_form do
        "flat" -> Map.merge(claim, record)
        _grouped -> %{"claim" => claim, "record" => record}
      end
      |> Map.merge(%{
        "@context" => HcpConformance.Envelope.context(),
        "type" => ["HCPEntry"],
        "credentialType" => "NLPreference"
      })

    Enum.reduce(Keyword.get(opts, :drop, []), body, fn path, acc ->
      drop(acc, ctx.envelope_form, path)
    end)
  end

  @doc "Creates an entry and returns the 201 body. Fails the check unless the target accepts it."
  @spec create!(Context.t(), String.t(), keyword()) :: map()
  def create!(ctx, token, opts \\ []) do
    response =
      Context.request(ctx, :post, Context.url(ctx, :preferences),
        token: token,
        json: entry_body(ctx, opts)
      )

    Assert.status!(response, 201, "POST /v1/preferences")
    entry = Assert.json_object!(response, "POST /v1/preferences")
    id = entry["id"]
    Assert.check!(is_binary(id), "POST /v1/preferences: the created entry has no id")
    Context.track_entry(ctx, id)
    entry
  end

  @doc "Searches as `token` and returns the 200 body."
  @spec search!(Context.t(), String.t(), map()) :: map()
  def search!(ctx, token, body) do
    body =
      Map.merge(
        %{"categories" => [ctx.primary_category], "purpose" => "HCP conformance check"},
        body
      )

    response = Context.request(ctx, :post, Context.url(ctx, :search), token: token, json: body)
    Assert.status!(response, 200, "POST /v1/preferences/search")
    Assert.json_object!(response, "POST /v1/preferences/search")
  end

  @doc "Reads one entry as `token`; returns the response."
  @spec get(Context.t(), String.t(), String.t(), keyword()) :: HcpConformance.HTTP.Response.t()
  def get(ctx, token, id, params \\ []) do
    Context.request(ctx, :get, Context.entry_url(ctx, id),
      token: token,
      params: Keyword.merge([purpose: "HCP conformance check"], params)
    )
  end

  @doc "Ids of the entries in a search or export body."
  @spec ids(map()) :: [String.t()]
  def ids(%{"entries" => entries}) when is_list(entries),
    do: Enum.map(entries, &(is_map(&1) && &1["id"]))

  def ids(_body), do: []

  defp compact(map),
    do:
      map
      |> Enum.reject(fn {key, value} -> is_nil(value) and key != "expirationDate" end)
      |> Map.new()

  defp drop(body, form, path) do
    [last | parents] = Enum.reverse(path)

    case form do
      "flat" ->
        [_group | rest] = path
        drop_in(body, rest)

      _grouped ->
        update_in(body, Enum.reverse(parents), &Map.delete(&1, last))
    end
  end

  defp drop_in(body, [key]), do: Map.delete(body, key)
  defp drop_in(body, [key | rest]), do: Map.update(body, key, %{}, &drop_in(&1, rest))
end
