defmodule HcpConformance.Reference.ModelV2 do
  @moduledoc """
  The pure rules of the HCP v2 reference implementation
  (`HcpConformance.Reference.ServerV2`): validating a write, what a grant
  reaches, standing rules, the disclosure a Context Client receives, and lexical
  relevance. No state and no HTTP, so each rule reads on its own.
  """

  @entry_schema "https://hcp.example/spec/entry/2.0"
  @general_context "https://hcp.example/spec/profiles/general-context/2.0"
  @access_type "https://hcp.example/spec/authorization/context-access"
  @declarations ~w(person-declared model-inferred issuer-attested)
  @actions ~w(read write provenance)
  @categories [
    {"general_preferences", "General preferences",
     "Communication style, formatting, language preferences", "low"},
    {"goals_and_constraints", "Goals and constraints",
     "Long-term goals, time constraints, stated priorities", "low"},
    {"health_context", "Health context", "Medical conditions, accessibility needs, medications",
     "high"},
    {"education_learner_profile", "Learner profile",
     "Mastery state, learning preferences, pacing", "medium"},
    {"work_context", "Work context", "Role, tools, professional preferences", "medium"},
    {"purchase_history_preferences", "Purchases", "Shopping preferences, brand affinities",
     "low"},
    {"values_and_ethics", "Values and ethics", "Stated ethical commitments, content boundaries",
     "medium"},
    {"location_context", "Location", "Geographic preferences and constraints", "medium"},
    {"coordination_context", "Coordination",
     "Scheduling rules, availability, relationship constraints", "medium"}
  ]

  @spec entry_schema() :: String.t()
  def entry_schema, do: @entry_schema

  @spec access_type() :: String.t()
  def access_type, do: @access_type

  @doc "The registered categories as the discovery document describes them (§19.3)."
  @spec described_categories() :: [map()]
  def described_categories do
    for {id, name, description, sensitivity} <- @categories do
      %{
        "id" => id,
        "name" => name,
        "description" => description,
        "sensitivity" => sensitivity,
        "registry" => "1"
      }
    end
  end

  @spec category?(term()) :: boolean()
  def category?(category), do: Enum.any?(@categories, &(elem(&1, 0) == category))

  @doc "Whether every category is a registered one whose default sensitivity is Low."
  @spec low_sensitivity?([String.t()]) :: boolean()
  def low_sensitivity?(categories) do
    Enum.all?(categories, fn category ->
      Enum.any?(@categories, fn {id, _, _, level} -> id == category and level == "low" end)
    end)
  end

  @spec high_sensitivity?([String.t()]) :: boolean()
  def high_sensitivity?(categories),
    do: Enum.any?(@categories, fn {id, _, _, level} -> level == "high" and id in categories end)

  # Writes (§5.2.3) -------------------------------------------------------------------

  @doc """
  Checks a create body. `{:error, slug, detail}` names the Core error; `opts`
  carries `subject` (the Context Subject's id) and `inferences` (whether the
  provider takes `model-inferred` entries, which it does only where it claims
  the Memory Manager Profile).
  """
  @spec validate_create(term(), keyword()) :: :ok | {:error, String.t(), String.t()}
  def validate_create(body, opts) when is_map(body) do
    checks = [
      &schema_error/2,
      &subject_error/2,
      &content_error/2,
      &evidence_error/2,
      &declaration_error/2,
      &categories_error/2,
      &provenance_error/2
    ]

    Enum.find_value(checks, :ok, fn check -> check.(body, opts) end)
  end

  def validate_create(_body, _opts),
    do: {:error, "malformed-request", "the body must be an entry object"}

  @doc "Checks the assertion members a revision carries (§5.2.4)."
  @spec validate_revision(map(), map(), keyword()) :: :ok | {:error, String.t(), String.t()}
  def validate_revision(body, current, opts) do
    assertion = Map.merge(current["assertion"], body["assertion"] || %{})

    merged = %{
      "content" => body["content"],
      "assertion" => assertion,
      "evidence" => body["evidence"]
    }

    cond do
      not is_integer(body["expectedVersion"]) ->
        {:error, "malformed-request", "expectedVersion is required"}

      not (is_binary(body["reason"]) and body["reason"] != "") ->
        {:error, "malformed-request", "reason is required"}

      true ->
        Enum.find_value(
          [&content_error/2, &evidence_error/2, &declaration_error/2],
          :ok,
          fn check -> check.(merged, opts) end
        )
    end
  end

  defp schema_error(%{"schema" => @entry_schema}, _opts), do: nil

  defp schema_error(_body, _opts),
    do: {:error, "malformed-request", "schema must be #{@entry_schema}"}

  defp subject_error(%{"subject" => %{"id" => id}}, opts) do
    if id == opts[:subject],
      do: nil,
      else: {:error, "malformed-request", "subject.id must identify the Context Subject"}
  end

  defp subject_error(_body, _opts), do: {:error, "malformed-request", "subject.id is required"}

  defp content_error(%{"content" => %{"profile" => @general_context, "value" => value}}, _opts)
       when (is_binary(value) and value != "") or is_map(value),
       do: nil

  defp content_error(_body, _opts),
    do:
      {:error, "malformed-request",
       "content must follow the General Context Profile: profile and a string or object value"}

  defp evidence_error(%{"evidence" => evidence}, _opts) when is_list(evidence) do
    if Enum.any?(evidence, &(is_map(&1) and &1["role"] == "content")),
      do:
        {:error, "malformed-request",
         "this implementation does not conform to the VC Evidence Profile"},
      else: nil
  end

  defp evidence_error(_body, _opts), do: nil

  defp declaration_error(%{"assertion" => %{"declarationType" => type} = assertion}, opts)
       when type in @declarations do
    confidence = assertion["confidence"]

    cond do
      type == "model-inferred" and confidence not in ~w(high medium low) ->
        {:error, "malformed-request", "a model-inferred entry needs a confidence"}

      type != "model-inferred" and confidence != nil ->
        {:error, "malformed-request", "confidence is for model-inferred entries only"}

      type == "model-inferred" and not Keyword.get(opts, :inferences, true) ->
        {:error, "malformed-request",
         "model-inferred entries are not accepted: the Memory Manager Profile is not claimed"}

      type == "issuer-attested" ->
        {:error, "scope-denied", "The request falls outside the caller's grant"}

      true ->
        nil
    end
  end

  defp declaration_error(_body, _opts),
    do: {:error, "malformed-request", "assertion.declarationType is required"}

  defp categories_error(%{"classification" => %{"categories" => categories}}, _opts)
       when is_list(categories) and categories != [] do
    cond do
      not Enum.all?(categories, &category?/1) ->
        {:error, "malformed-request", "a category is not one this implementation holds"}

      Enum.uniq(categories) != categories ->
        {:error, "malformed-request", "classification.categories has duplicates"}

      true ->
        nil
    end
  end

  defp categories_error(_body, _opts),
    do: {:error, "malformed-request", "classification.categories is required"}

  # §5.2.3: the source always; the asserter unless the person is declared to be it.
  defp provenance_error(body, _opts) do
    provenance = get_in(body, ["record", "provenance"]) || %{}
    declared? = get_in(body, ["assertion", "declarationType"]) == "person-declared"

    cond do
      not is_binary(provenance["source"]) ->
        {:error, "malformed-request", "record.provenance.source is required"}

      not declared? and not is_binary(get_in(provenance, ["assertedBy", "id"])) ->
        {:error, "malformed-request",
         "record.provenance.assertedBy.id names the asserter of an entry the person did not declare"}

      true ->
        nil
    end
  end

  @doc "A categories list a governance change may set (§4.2.1)."
  @spec valid_categories?(term()) :: boolean()
  def valid_categories?(categories),
    do: categories_error(%{"classification" => %{"categories" => categories}}, []) == nil

  # Grants (§6.1.5) -------------------------------------------------------------------

  @doc "Checks the `access` a hook request asks for; unknown narrowing fails closed (§6.1.5.1)."
  @spec access_error(term()) :: String.t() | nil
  def access_error(access) when is_list(access) and access != [] do
    if Enum.all?(access, &detail?/1), do: nil, else: "an access detail is not valid"
  end

  def access_error(_access), do: "access must be a non-empty array"

  defp detail?(
         %{"actions" => actions, "categories" => categories, "purposes" => purposes} = detail
       ) do
    actions?(actions) and every?(categories, &category?/1) and every?(purposes, &purpose?/1) and
      narrowing?(detail["narrowedTo"]) and sharing?(detail)
  end

  defp detail?(_detail), do: false

  # `provenance` is an action only alongside `read` (§6.1.5).
  defp actions?(actions) do
    every?(actions, &(&1 in @actions)) and ("provenance" not in actions or "read" in actions)
  end

  defp every?(list, valid?), do: is_list(list) and list != [] and Enum.all?(list, valid?)

  # Onward sharing is elected only for a detail that reads, all of whose
  # categories are Low sensitivity (§6.1.5).
  defp sharing?(%{"onwardSharing" => sharing, "actions" => actions, "categories" => categories}) do
    is_map(sharing) and "read" in actions and low_sensitivity?(categories) and
      (is_nil(sharing["domains"]) or every?(sharing["domains"], &is_binary/1))
  end

  defp sharing?(_detail), do: true

  defp purpose?(%{"code" => code, "description" => description}),
    do: is_binary(code) and code != "" and is_binary(description)

  defp purpose?(_purpose), do: false

  defp narrowing?(nil), do: true

  defp narrowing?(%{"entryIds" => ids} = narrowed),
    do: map_size(narrowed) == 1 and is_list(ids) and Enum.all?(ids, &is_binary/1)

  defp narrowing?(_narrowed), do: false

  @doc "Scope strings derived from `access` (§6.1.1)."
  @spec scopes([map()]) :: [String.t()]
  def scopes(access) do
    for detail <- access,
        category <- detail["categories"],
        action <- detail["actions"],
        action in ["read", "write"],
        uniq: true,
        do: "hcp:#{category}:#{action}"
  end

  @doc "The categories a grant holds `action` on, whatever the purpose."
  @spec categories_for(map(), String.t()) :: [String.t()]
  def categories_for(grant, action) do
    for detail <- grant["access"],
        action in detail["actions"],
        category <- detail["categories"],
        uniq: true do
      category
    end
  end

  @doc "The categories a grant may read for `purpose` (§6.1.5.2)."
  @spec readable_categories(map(), String.t()) :: [String.t()]
  def readable_categories(grant, purpose) do
    for detail <- grant["access"],
        "read" in detail["actions"],
        Enum.any?(detail["purposes"], &(&1["code"] == purpose)),
        category <- detail["categories"],
        uniq: true,
        do: category
  end

  @doc """
  Whether a grant reaches an entry for `action`: a detail covering one of its
  categories, the purpose approved for a read, and the entry inside any
  `narrowedTo` (§6.1.5.1 rule 4).
  """
  @spec reaches?(map(), map(), String.t(), String.t() | nil) :: boolean()
  def reaches?(grant, entry, action, purpose) do
    categories = entry["classification"]["categories"]

    Enum.any?(grant["access"], fn detail ->
      action in detail["actions"] and
        Enum.any?(detail["categories"], &(&1 in categories)) and
        (action != "read" or Enum.any?(detail["purposes"], &(&1["code"] == purpose))) and
        within?(detail["narrowedTo"], entry["id"])
    end)
  end

  defp within?(nil, _id), do: true
  defp within?(%{"entryIds" => ids}, id), do: id in ids

  @doc "Whether the entry's own purpose lists allow `purpose` (§4.2.6)."
  @spec purpose_permitted?(map(), String.t()) :: boolean()
  def purpose_permitted?(entry, purpose) do
    [entry["assertion"]["permittedPurposes"], entry["classification"]["permittedPurposes"]]
    |> Enum.filter(&is_list/1)
    |> Enum.all?(&(purpose in &1))
  end

  # Standing rules and directives (§6.3, §6.4) ------------------------------------------

  @doc "The categories standing rules deny a grant's Client Operator; `:all` for every category."
  @spec denied_categories([map()], map()) :: :all | [String.t()]
  def denied_categories(rules, grant) do
    rules
    |> Enum.filter(&rule_applies?(&1, grant))
    |> Enum.reduce([], fn
      _rule, :all -> :all
      %{"categories" => categories}, acc when is_list(categories) -> acc ++ categories
      _unscoped, _acc -> :all
    end)
  end

  defp rule_applies?(rule, grant) do
    client = grant["client"]
    claims = client["claims"] || []

    operator_matches?(rule["operators"], client["operator"]["id"]) and
      (rule["requires"] in [nil, []] or not Enum.all?(rule["requires"], &(&1 in claims)))
  end

  @doc "Whether an operator list names an operator: a DNS domain or an exact identifier."
  @spec operator_matches?([String.t()] | nil, String.t()) :: boolean()
  def operator_matches?(nil, _operator), do: true

  def operator_matches?(operators, operator) do
    host = URI.parse(operator).host || ""

    Enum.any?(operators, fn named ->
      named == operator or named == host or String.ends_with?(host, "." <> named)
    end)
  end

  @spec denied?(:all | [String.t()], [String.t()]) :: boolean()
  def denied?(:all, _categories), do: true
  def denied?(denied, categories), do: Enum.any?(categories, &(&1 in denied))

  @doc "The directives delivered with a result: operator matched, and scoped to a disclosed category."
  @spec directives_for([map()], map(), [String.t()]) :: [map()]
  def directives_for(directives, grant, categories) do
    operator = grant["client"]["operator"]["id"]

    Enum.filter(directives, fn directive ->
      operator_matches?(directive["operators"], operator) and
        (is_nil(directive["categories"]) or
           Enum.any?(directive["categories"], &(&1 in categories)))
    end)
  end

  # Disclosure (§7.4, §7.6) --------------------------------------------------------------

  @doc "The disclosure of an entry version to the client holding `grant`."
  @spec disclosure(map(), map(), String.t(), DateTime.t(), boolean()) :: map()
  def disclosure(entry, grant, ref, now, long_use?) do
    held = Enum.uniq(categories_for(grant, "read") ++ categories_for(grant, "write"))
    classification = entry["classification"]
    provenance = entry["record"]["provenance"]

    %{
      "ref" => ref,
      "version" => entry["record"]["version"],
      "content" => entry["content"],
      "evidence" => entry["evidence"] || [],
      "assertion" => entry["assertion"],
      "classification" =>
        classification
        |> Map.take(["dimension", "permittedPurposes"])
        |> Map.put("categories", Enum.filter(classification["categories"], &(&1 in held))),
      "standing" => %{
        "assurance" => provenance["assertedBy"]["assurance"],
        "confirmed" => confirmed?(provenance["confirmations"])
      },
      "useUntil" => DateTime.to_iso8601(use_until(entry, now, long_use?))
    }
    |> put_shareable(shareable?(grant, entry))
  end

  # §7.4: present, and true, only where the client may share the entry onward.
  defp put_shareable(disclosure, true), do: Map.put(disclosure, "onwardSharing", true)
  defp put_shareable(disclosure, false), do: disclosure

  @doc """
  Whether the client holding `grant` may share an entry onward (§3.12): a detail
  that reads the entry elected onward sharing, and every category of the entry,
  those the grant does not cover included, is Low sensitivity.
  """
  @spec shareable?(map(), map()) :: boolean()
  def shareable?(grant, entry), do: sharing(grant, entry) != nil

  @doc "Whether a share with the organization at `domain` is one the grant allows for the entry."
  @spec share_permitted?(map(), map(), String.t()) :: boolean()
  def share_permitted?(grant, entry, domain) do
    case sharing(grant, entry) do
      nil ->
        false

      sharing ->
        (is_nil(sharing["domains"]) or operator_matches?(sharing["domains"], "https://" <> domain)) and
          not operator_matches?(sharing["notTo"] || [], "https://" <> domain)
    end
  end

  # The onwardSharing election of the detail through which the grant reads the entry.
  defp sharing(grant, entry) do
    categories = entry["classification"]["categories"]

    if low_sensitivity?(categories),
      do: Enum.find_value(grant["access"], &election(&1, categories, entry["id"]))
  end

  defp election(detail, categories, id) do
    reads? = "read" in detail["actions"] and Enum.any?(detail["categories"], &(&1 in categories))
    if reads? and within?(detail["narrowedTo"], id), do: detail["onwardSharing"]
  end

  defp confirmed?(confirmations),
    do: match?(%{"disposition" => "confirmed"}, List.last(confirmations || []))

  # No client of the reference registers a notification endpoint, so a copy is
  # usable for an hour at most (§7.6 rule 4); an earlier validUntil still applies.
  defp use_until(_entry, now, true), do: DateTime.add(now, 7 * 86_400, :second)

  defp use_until(entry, now, false) do
    hour = DateTime.add(now, 3600, :second)

    with until when is_binary(until) <- entry["assertion"]["validUntil"],
         {:ok, valid, _offset} <- DateTime.from_iso8601(until),
         :lt <- DateTime.compare(valid, hour) do
      valid
    else
      _other -> hour
    end
  end

  @doc "Whether an entry's validity has passed (§4.2.4)."
  @spec lapsed?(map(), DateTime.t()) :: boolean()
  def lapsed?(entry, now) do
    with until when is_binary(until) <- entry["assertion"]["validUntil"],
         {:ok, valid, _offset} <- DateTime.from_iso8601(until) do
      DateTime.compare(valid, now) != :gt
    else
      _other -> false
    end
  end

  # Relevance (§7.3): lexical -----------------------------------------------------------

  @doc "How many distinct query terms an entry's statement and dimension share with the query."
  @spec score(String.t(), map()) :: non_neg_integer()
  def score(query, entry) do
    terms = tokens(entry["content"]["value"]) ++ tokens(entry["classification"]["dimension"])
    query |> tokens() |> Enum.count(&(&1 in terms))
  end

  defp tokens(nil), do: []

  defp tokens(text) when is_binary(text) do
    text |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true) |> Enum.uniq()
  end

  defp tokens(other), do: tokens(Jason.encode!(other))
end
