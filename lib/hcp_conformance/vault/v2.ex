defmodule HcpConformance.Vault.V2 do
  @moduledoc """
  What the chat page's vault client (`HcpConformance.Vault`) sends an HCP v2
  vault where the wire differs from v1: a grant described by its access and an
  approved purpose (§6.1.5), an entry in the v2 form (§4.2), a query naming a
  purpose code (§5.2.1), and the grant list, which v2 filters by one status at a
  time (§9.4.6).
  """

  alias HcpConformance.{Context, V2.Fixtures}

  @purpose "https://conformance.hcp.example/purposes/assistant-reply"
  @description "Answer the person's message"
  @statuses ~w(active revoked expired)

  @doc "The purpose code every grant issued on the chat page approves."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "The statuses a grant list is asked for in turn."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  The access of a grant: one detail for the categories and actions, or, where
  reads are narrowed to particular memories, a narrowed detail for the read and
  an unnarrowed one for anything else granted (§6.1.5.1).
  """
  @spec access(map()) :: [map()]
  def access(%{categories: categories, actions: actions} = attrs) do
    detail = %{
      "categories" => categories,
      "purposes" => [%{"code" => @purpose, "description" => @description}]
    }

    case {attrs[:restrict_to], actions -- ["read"]} do
      {ids, _others} when ids in [nil, []] ->
        [Map.put(detail, "actions", actions)]

      {ids, others} ->
        narrowed =
          Map.merge(detail, %{"actions" => ["read"], "narrowedTo" => %{"entryIds" => ids}})

        if others == [], do: [narrowed], else: [narrowed, Map.put(detail, "actions", others)]
    end
  end

  @doc "The body of a create for a memory. An assistant's inference names the assistant as its asserter."
  @spec entry_body(Context.t(), :person | String.t(), map()) :: map()
  def entry_body(context, author, attrs) do
    declaration = attrs[:declaration_type] || "person-declared"

    Fixtures.entry_body(context,
      value: attrs.text,
      categories: [attrs.category],
      dimension: attrs[:dimension],
      declaration_type: declaration,
      confidence: attrs[:confidence],
      asserted_by: if(declaration != "person-declared", do: asserter(author))
    )
  end

  defp asserter(:person), do: "urn:hcp:conformance:person-input"
  defp asserter(_assistant), do: "urn:hcp:conformance:assistant"

  @doc "The body of a query: the approved purpose code, with the person's words for it as its description."
  @spec query_body(String.t(), [String.t()], keyword()) :: map()
  def query_body(query, categories, opts) do
    %{
      "query" => query,
      "categories" => categories,
      "purpose" => @purpose,
      "purposeDescription" => opts[:purpose] || @description,
      "maxEntries" => opts[:max_entries] || 5
    }
  end
end
