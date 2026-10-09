defmodule HcpConformance.Checks.Discovery do
  @moduledoc """
  The discovery document (§3.3, Appendix C): what an implementation declares
  about itself. The rest of the suite holds the target to these declarations
  (minimization method, envelope form, durability window), so they are checked
  first.
  """

  alias HcpConformance.{Assert, Check, Context}

  @levels ["HCP-v1-Core", "HCP-v1-Interop", "HCP-v1-VC-Extended"]
  @profiles ["oauth2", "first-party"]
  @forms ["grouped", "flat"]
  @methods ["lexical", "semantic", "llm"]
  @transports ["mcp", "rest"]
  @mechanisms ["data-integrity", "vc-jose-cose"]
  @core_members ~w(hcp_version issuer preferences_endpoint grants_endpoint audit_endpoint export_endpoint
                   supported_categories supported_transports conformance_level authorization_profile
                   envelope_form minimization_method audit_durability problem_type_base)

  def group, do: "discovery"

  # Every discovery check judges the document fetched during setup.
  def checks do
    Enum.map(declared(), &%{&1 | evidence: :discovery})
  end

  defp declared do
    [
      Check.new(
        "discovery.served",
        "3.3",
        :must,
        "A discovery document is published at /.well-known/hcp-configuration",
        &served/1
      ),
      Check.new(
        "discovery.media_type",
        "3.3",
        :must,
        "The discovery document is served as application/ld+json",
        &media_type/1
      ),
      Check.new(
        "discovery.required_members",
        "App. C",
        :must,
        "The document carries every Appendix C member that applies to its transports and authorization profile",
        &required_members/1
      ),
      Check.new(
        "discovery.declared_values",
        "App. C",
        :must,
        "Declared values come from the specification's vocabularies",
        &declared_values/1
      ),
      Check.new(
        "discovery.categories",
        "2.5",
        :must,
        "Supported categories are registered slugs or use the hcp-custom: prefix",
        &categories/1
      ),
      Check.new(
        "discovery.audit_durability",
        "4.3.4",
        :must,
        "A bounded audit durability window is declared only for preference.read, and is at most 10 000 ms",
        &durability/1
      ),
      Check.new(
        "discovery.pagination",
        "3.4.2",
        :must,
        "An implementation with the REST transport declares cursor pagination for the audit log",
        &pagination/1
      ),
      Check.new(
        "discovery.profile",
        "5.2.1",
        :must,
        "A first-party implementation does not claim HCP v1 Interop",
        &profile/1
      ),
      Check.new(
        "discovery.tier2_securing",
        "2.4.1",
        :must,
        "Tier 2 support is declared consistently: securing mechanisms when VC-Extended is claimed, and the grouped form",
        &tier2/1
      ),
      Check.new(
        "discovery.rate_limits",
        "3.4.5",
        :should,
        "The rate-limit policy is published in the discovery document",
        &rate_limits/1
      )
    ]
  end

  @doc "The discovery document, or a failure saying why there is none."
  @spec discovery!(Context.t()) :: map()
  def discovery!(%Context{discovery: discovery}) when is_map(discovery), do: discovery

  def discovery!(%Context{discovery_response: %{} = response}) do
    Assert.status!(response, 200, "GET /.well-known/hcp-configuration")
    Assert.json_object!(response, "GET /.well-known/hcp-configuration")
  end

  def discovery!(%Context{setup_notes: notes}),
    do: Assert.fail!("the discovery document could not be fetched: " <> Enum.join(notes, "; "))

  defp served(ctx), do: discovery!(ctx)

  defp media_type(ctx) do
    discovery!(ctx)
    type = ctx.discovery_response.content_type

    Assert.check!(
      type == "application/ld+json",
      "expected content-type application/ld+json, got #{inspect(type)}"
    )
  end

  defp required_members(ctx) do
    doc = discovery!(ctx)
    transports = List.wrap(doc["supported_transports"])

    required =
      @core_members ++
        if(doc["authorization_profile"] == "oauth2",
          do: ~w(authorization_endpoint token_endpoint revocation_endpoint),
          else: []
        ) ++
        if("mcp" in transports, do: ["mcp_manifest_endpoint"], else: []) ++
        if("rest" in transports, do: ["pagination"], else: [])

    missing = Enum.reject(required, &Map.has_key?(doc, &1))
    Assert.check!(missing == [], "missing members: " <> Enum.join(missing, ", "))
  end

  defp declared_values(ctx) do
    doc = discovery!(ctx)
    transports = doc["supported_transports"]

    problems =
      [
        {doc["hcp_version"] == "1.0",
         "hcp_version must be \"1.0\", got #{inspect(doc["hcp_version"])}"},
        {doc["conformance_level"] in @levels,
         "conformance_level must be one of #{inspect(@levels)}"},
        {doc["authorization_profile"] in @profiles,
         "authorization_profile must be one of #{inspect(@profiles)}"},
        {doc["envelope_form"] in @forms, "envelope_form must be one of #{inspect(@forms)}"},
        {doc["minimization_method"] in @methods,
         "minimization_method must be one of #{inspect(@methods)}"},
        {is_list(transports) and transports != [] and Enum.all?(transports, &(&1 in @transports)),
         "supported_transports must be a non-empty subset of #{inspect(@transports)}"},
        {doc["problem_type_base"] == "https://hcp.me/problems/",
         "problem_type_base must be \"https://hcp.me/problems/\" (§3.4.4), got #{inspect(doc["problem_type_base"])}"},
        {get_in(doc, ["audit_durability", "default"]) in [nil, "synchronous"],
         "audit_durability.default must be \"synchronous\": every event other than preference.read is durable before acknowledgement (§4.3.4)"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  defp categories(ctx) do
    categories = discovery!(ctx)["supported_categories"]

    Assert.check!(
      is_list(categories) and categories != [],
      "supported_categories must be a non-empty array"
    )

    unknown =
      Enum.reject(categories, fn category ->
        category in Context.registered_categories() or
          (is_binary(category) and String.starts_with?(category, "hcp-custom:"))
      end)

    Assert.check!(unknown == [], "not registered and not hcp-custom: #{inspect(unknown)}")
  end

  defp durability(ctx) do
    durability = discovery!(ctx)["audit_durability"]
    Assert.check!(is_map(durability), "audit_durability must be an object")
    bounded = durability["bounded"] || %{}
    Assert.check!(is_map(bounded), "audit_durability.bounded must be an object")
    others = Map.keys(bounded) -- ["preference.read"]

    Assert.check!(
      others == [],
      "a bounded window may only be declared for preference.read, found #{inspect(others)}"
    )

    case bounded["preference.read"] do
      nil ->
        :ok

      ms when is_integer(ms) and ms >= 0 and ms <= 10_000 ->
        :ok

      other ->
        Assert.fail!(
          "the preference.read window must be an integer of at most 10 000 ms, got #{inspect(other)}"
        )
    end
  end

  defp pagination(ctx) do
    doc = discovery!(ctx)

    if "rest" not in List.wrap(doc["supported_transports"]),
      do: Assert.not_applicable!("the REST transport is not offered")

    Assert.check!(
      get_in(doc, ["pagination", "audit"]) == "cursor",
      "pagination.audit must be \"cursor\""
    )
  end

  defp profile(ctx) do
    doc = discovery!(ctx)

    Assert.check!(
      not (doc["authorization_profile"] == "first-party" and
             doc["conformance_level"] == "HCP-v1-Interop"),
      "a first-party implementation is not eligible for HCP v1 Interop"
    )
  end

  defp tier2(ctx) do
    doc = discovery!(ctx)
    securing = doc["tier2_securing"]

    cond do
      doc["conformance_level"] == "HCP-v1-VC-Extended" and not is_map(securing) ->
        Assert.fail!("VC-Extended is claimed but tier2_securing is missing")

      is_map(securing) ->
        verifies = securing["verifies"]
        issues = securing["issues"]

        Assert.check!(
          is_list(verifies) and verifies != [] and Enum.all?(verifies, &(&1 in @mechanisms)),
          "tier2_securing.verifies must name at least one of #{inspect(@mechanisms)}"
        )

        Assert.check!(
          is_list(issues) and Enum.all?(issues, &(&1 in @mechanisms)),
          "tier2_securing.issues must list mechanisms"
        )

        Assert.check!(
          doc["envelope_form"] == "grouped",
          "an implementation supporting Tier 2 emits the grouped form"
        )

      true ->
        :ok
    end
  end

  defp rate_limits(ctx) do
    Assert.check!(is_map(discovery!(ctx)["rate_limits"]), "no rate_limits member")
  end
end
