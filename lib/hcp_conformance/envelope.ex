defmodule HcpConformance.Envelope do
  @moduledoc """
  The HCP entry envelope (§2.2): reading fields in either envelope form, and
  validating an entry against the data-model rules.

  HCP has not published its Tier 1 JSON Schema yet (Appendix D), so the rules are
  the specification's own, written out here. Each violation is reported as a
  sentence naming the field and the rule.
  """

  @context ["https://www.w3.org/ns/credentials/v2", "https://hcp.me/contexts/v1"]
  @declaration_types ["user-declared", "model-inferred", "issuer-attested"]
  @statuses ["active", "deprecated", "conflicted", "deleted"]
  @confidences ["high", "medium", "low"]
  @urn_uuid ~r/^urn:uuid:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  @iso8601 ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$/

  @doc "The constant `@context` of every entry."
  @spec context() :: [String.t()]
  def context, do: @context

  @doc """
  Reads a field by its grouped path (`["record", "status"]`). In the flat form
  (§2.2.1) the members of `claim` and `record` sit at the top level, so the first
  segment is dropped.
  """
  @spec get(map(), String.t(), [String.t()]) :: term()
  def get(entry, "flat", [group | rest]) when group in ["claim", "record"], do: get_in(entry, rest)
  def get(entry, _form, path), do: get_in(entry, path)

  @doc "The literal path of a grouped field in the given form, as `redactedFields` must report it (§4.4.5)."
  @spec path(String.t(), [String.t()]) :: String.t()
  def path("flat", [group | rest]) when group in ["claim", "record"], do: Enum.join(rest, ".")
  def path(_form, path), do: Enum.join(path, ".")

  @doc "Whether a string is an ISO-8601 timestamp."
  @spec iso8601?(term()) :: boolean()
  def iso8601?(value), do: is_binary(value) and Regex.match?(@iso8601, value)

  @doc "Whether a string is a `urn:uuid:` identifier."
  @spec urn_uuid?(term()) :: boolean()
  def urn_uuid?(value), do: is_binary(value) and Regex.match?(@urn_uuid, value)

  @doc """
  Validates an entry. Returns the list of violations, empty when valid.

  `redacted: true` accepts entries returned to a non-person actor, from which
  `record.provenance.source` and `capturedBy` are omitted (§4.4.4).
  """
  @spec validate(term(), String.t(), keyword()) :: [String.t()]
  def validate(entry, form, opts \\ [])

  def validate(entry, form, opts) when is_map(entry) do
    field = &get(entry, form, &1)
    tier2? = entry["credentialType"] == "VerifiablePreference"

    ([
       check(entry["@context"] == @context, "@context must be exactly #{inspect(@context)} (§2.1.1)"),
       check(urn_uuid?(entry["id"]), "id must be a urn:uuid identifier (§2.2)"),
       check(
         is_list(entry["type"]) and "HCPEntry" in entry["type"],
         "type must be an array including \"HCPEntry\""
       ),
       check(
         entry["credentialType"] in ["NLPreference", "VerifiablePreference"],
         "credentialType must be NLPreference or VerifiablePreference"
       ),
       check(not tier2? or form == "grouped", "Tier 2 entries must use the grouped form (§2.2.1)"),
       check(form != "grouped" or is_map(entry["record"]), "record must be an object in the grouped form"),
       check(form != "grouped" or is_map(entry["claim"]), "claim must be an object in the grouped form")
     ] ++
       if(tier2?, do: tier2_claim(entry), else: tier1_claim(field)) ++
       record(field, opts))
    |> Enum.reject(&is_nil/1)
  end

  def validate(_entry, _form, _opts), do: ["entry must be a JSON object"]

  defp tier1_claim(field) do
    expiration = field.(["claim", "expirationDate"])
    preference = field.(["claim", "subject", "preference"])

    [
      check(is_binary(field.(["claim", "issuer", "id"])), "claim.issuer.id must be a string"),
      check(iso8601?(field.(["claim", "issuanceDate"])), "claim.issuanceDate must be an ISO-8601 timestamp"),
      check(is_nil(expiration) or iso8601?(expiration), "claim.expirationDate must be null or ISO-8601"),
      check(is_binary(field.(["claim", "subject", "id"])), "claim.subject.id must be a string"),
      check(
        is_binary(preference) or is_map(preference),
        "claim.subject.preference must be a string or an object"
      )
    ]
  end

  defp tier2_claim(entry) do
    claim = entry["claim"] || %{}

    [
      check(is_map(claim["credentialSubject"]), "a Tier 2 claim must carry credentialSubject (§2.2)"),
      check(
        is_map(claim["proof"]) or "EnvelopedVerifiableCredential" in List.wrap(claim["type"]),
        "a Tier 2 claim must carry a proof or be an EnvelopedVerifiableCredential (§2.4.1)"
      )
    ]
  end

  defp record(field, opts) do
    declaration = field.(["record", "declarationType"])
    confidence = field.(["record", "confidence"])
    version = field.(["record", "version"])
    previous = field.(["record", "previousVersion"])
    category = field.(["record", "category"])
    dimension = field.(["record", "dimension"])

    [
      check(is_binary(category) and category != "", "record.category must be a non-empty string"),
      check(is_nil(dimension) or is_binary(dimension), "record.dimension must be a string or null"),
      check(
        declaration in @declaration_types,
        "record.declarationType must be one of #{inspect(@declaration_types)}"
      ),
      if(declaration == "model-inferred",
        do:
          check(
            confidence in @confidences,
            "record.confidence must be high, medium or low for a model-inferred entry"
          ),
        else: check(is_nil(confidence), "record.confidence must be null unless the entry is model-inferred")
      ),
      check(field.(["record", "status"]) in @statuses, "record.status must be one of #{inspect(@statuses)}"),
      check(is_integer(version) and version >= 1, "record.version must be a positive integer"),
      cond do
        version == 1 ->
          check(is_nil(previous), "record.previousVersion must be null or absent at version 1")

        is_integer(version) ->
          check(previous == version - 1, "record.previousVersion must be record.version - 1")

        true ->
          nil
      end
    ] ++ provenance(field, opts)
  end

  defp provenance(field, opts) do
    provenance = field.(["record", "provenance"])

    if is_map(provenance) do
      [
        check(
          Keyword.get(opts, :redacted, false) or is_binary(provenance["source"]),
          "record.provenance.source must be a string"
        ),
        check(
          iso8601?(provenance["capturedAt"]),
          "record.provenance.capturedAt must be an ISO-8601 timestamp"
        ),
        check(is_boolean(provenance["userVerified"]), "record.provenance.userVerified must be a boolean")
      ]
    else
      ["record.provenance must be an object"]
    end
  end

  defp check(true, _message), do: nil
  defp check(_false, message), do: message
end
