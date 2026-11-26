defmodule HcpConformance.V2.Checks.Discovery do
  @moduledoc """
  The v2 discovery document (§19) and the conformance claims it carries (§18):
  what an implementation says it is. The rest of the run holds the target to
  these declarations, so they are checked first.
  """

  alias HcpConformance.{Assert, Check, Context}

  @base "https://hcp.example/spec/"
  @core @base <> "core/2.0"
  @bindings %{"http" => @base <> "bindings/http/2.0", "mcp" => @base <> "bindings/mcp/2.0"}
  @first_party @base <> "profiles/first-party-authorization/2.0"
  @oauth @base <> "profiles/oauth-interop/2.0"
  @vc @base <> "profiles/vc-evidence/2.0"
  @memory @base <> "profiles/memory-manager/2.0"
  @health @base <> "profiles/health-context/2.0"
  @education @base <> "profiles/education-context/2.0"
  @delegated @base <> "profiles/delegated-authorization/2.0"

  @required ~w(hcp_version provider provider_operator conformsTo bindings jwks_uri supported_categories
               category_registry accepts_entry_schemas minimization_method audit_durability audit_integrity
               storage_encryption)
  @http_members ~w(entries_endpoint grants_endpoint audit_endpoint export_endpoint rules_endpoint
                   directives_endpoint pagination problem_type_base)
  @integrity ~w(append-only hash-chained signed-checkpoints anchored)
  @mechanisms ~w(eddsa-rdfc-2022 ecdsa-sd-2023 vc-jose-cose)

  def group, do: "discovery"

  @doc "The Memory Manager Profile's conformance identifier."
  @spec memory_manager() :: String.t()
  def memory_manager, do: @memory

  # Every discovery check judges the document fetched during setup.
  def checks, do: Enum.map(declared(), &%{&1 | evidence: :discovery})

  defp declared do
    [
      Check.new(
        "discovery.served",
        "19.1",
        :must,
        "A discovery document is published as JSON at /.well-known/hcp-configuration",
        &discovery!/1
      ),
      Check.new(
        "discovery.required_members",
        "19.3",
        :must,
        "The document carries every member required of every implementation, and of the HTTP Binding where exposed",
        &required_members/1
      ),
      Check.new(
        "discovery.declared_values",
        "19.3",
        :must,
        "Declared values come from the specification's vocabularies",
        &declared_values/1
      ),
      Check.new(
        "discovery.claims",
        "18.1",
        :must,
        "conformsTo lists Core, and the bindings listed match the binding identifiers claimed",
        &claims/1
      ),
      Check.new(
        "discovery.profiles",
        "12.2",
        :must,
        "Profile claims are consistent: First-Party excludes OAuth Interop, and Health or Education brings VC Evidence",
        &profiles/1
      ),
      Check.new(
        "discovery.profile_members",
        "19.3",
        :must,
        "Members tied to a profile are present when it is claimed and omitted when it is not",
        &profile_members/1
      ),
      Check.new(
        "discovery.categories",
        "4.5",
        :must,
        "Each supported category is described, and a custom category is a URI that is never Low sensitivity",
        &categories/1
      ),
      Check.new(
        "discovery.audit_durability",
        "8.4",
        :must,
        "A bounded audit durability window is declared only for context.read, and is at most 10 000 ms",
        &durability/1
      ),
      Check.new(
        "discovery.pagination",
        "9.5",
        :must,
        "An implementation exposing the HTTP Binding declares cursor pagination for the audit log",
        &pagination/1
      ),
      Check.new(
        "discovery.rate_limits",
        "9.8",
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

  defp claimed(doc), do: Enum.filter(List.wrap(doc["conformsTo"]), &is_binary/1)
  defp bindings(doc), do: List.wrap(doc["bindings"])

  defp fail_unless_empty!(problems) do
    Assert.check!(problems == [], Enum.join(problems, "; "))
  end

  defp failing(pairs), do: for({false, message} <- pairs, do: message)

  defp required_members(ctx) do
    doc = discovery!(ctx)
    required = @required ++ if("http" in bindings(doc), do: @http_members, else: [])
    missing = Enum.reject(required, &Map.has_key?(doc, &1))
    Assert.check!(missing == [], "missing members: " <> Enum.join(missing, ", "))
  end

  defp declared_values(ctx) do
    doc = discovery!(ctx)
    operator = doc["provider_operator"]
    method = doc["minimization_method"]

    [
      {doc["hcp_version"] == "2.0",
       "hcp_version must be \"2.0\", got #{inspect(doc["hcp_version"])}"},
      {is_binary(doc["provider"]) and doc["provider"] != "",
       "provider must be the provider's base URL"},
      {is_map(operator) and is_binary(operator["id"]) and is_binary(operator["name"]),
       "provider_operator must carry an id and a name"},
      {bindings(doc) != [] and Enum.all?(bindings(doc), &Map.has_key?(@bindings, &1)),
       "bindings must be a non-empty subset of [\"http\", \"mcp\"]"},
      {is_binary(method) and method not in ["", "none"],
       "minimization_method must name a relevance method; \"none\" is not a valid declaration"},
      {doc["audit_integrity"] in @integrity,
       "audit_integrity must be one of #{inspect(@integrity)}"},
      {doc["storage_encryption"] in ["server", "e2e"],
       "storage_encryption must be \"server\" or \"e2e\""},
      {get_in(doc, ["audit_durability", "default"]) == "synchronous",
       "audit_durability.default must be \"synchronous\""},
      {is_list(doc["accepts_entry_schemas"]) and
         "https://hcp.example/spec/entry/2.0" in doc["accepts_entry_schemas"],
       "accepts_entry_schemas must include this draft's entry schema"}
    ]
    |> failing()
    |> fail_unless_empty!()
  end

  defp claims(ctx) do
    doc = discovery!(ctx)
    claimed = claimed(doc)

    Assert.check!(
      is_list(doc["conformsTo"]) and claimed != [],
      "conformsTo must be a non-empty array of identifiers"
    )

    mismatched =
      for {binding, identifier} <- @bindings, binding in bindings(doc) != identifier in claimed do
        "the #{binding} binding is #{if binding in bindings(doc), do: "listed in bindings but not claimed in conformsTo", else: "claimed in conformsTo but not listed in bindings"}"
      end

    fail_unless_empty!(
      failing([{@core in claimed, "conformsTo does not list Core (#{@core})"}]) ++ mismatched
    )
  end

  defp profiles(ctx) do
    claimed = ctx |> discovery!() |> claimed()

    [
      {not (@first_party in claimed and @oauth in claimed),
       "the First-Party Authorization Profile and the OAuth Interop Profile are both claimed"},
      {@oauth not in claimed or @bindings["http"] in claimed,
       "the OAuth Interop Profile is claimed without the HTTP Binding, which Provider Interop requires"},
      {not (@health in claimed or @education in claimed) or @vc in claimed,
       "a Health or Education Context Profile is claimed without the VC Evidence Profile"}
    ]
    |> failing()
    |> fail_unless_empty!()
  end

  defp profile_members(ctx) do
    doc = discovery!(ctx)
    claimed = claimed(doc)

    tied = [
      {@memory, ["conflict_detection"], true},
      {@vc, ["vc_securing", "credential_status_interval"], true},
      {@oauth, ["protected_resource_metadata"], false},
      {@delegated, if("http" in bindings(doc), do: ["delegations_endpoint"], else: []), false}
    ]

    problems =
      for {profile, members, exclusive?} <- tied,
          member <- members,
          problem = tied_problem(doc, claimed, profile, member, exclusive?) do
        problem
      end

    fail_unless_empty!(problems ++ securing_problems(doc, claimed))
  end

  defp tied_problem(doc, claimed, profile, member, exclusive?) do
    cond do
      profile in claimed and not Map.has_key?(doc, member) ->
        "#{member} is required when #{profile} is claimed"

      exclusive? and profile not in claimed and Map.has_key?(doc, member) ->
        "#{member} is present but #{profile} is not claimed"

      true ->
        nil
    end
  end

  defp securing_problems(doc, claimed) do
    if @vc in claimed and is_map(doc["vc_securing"]) do
      verifies = doc["vc_securing"]["verifies"]
      interval = doc["credential_status_interval"]
      ceiling = if @health in claimed, do: 3600, else: 86_400

      failing([
        {is_list(verifies) and "eddsa-rdfc-2022" in verifies and
           Enum.all?(verifies, &(&1 in @mechanisms)),
         "vc_securing.verifies must list registered mechanisms and include eddsa-rdfc-2022"},
        {is_integer(interval) and interval > 0 and interval <= ceiling,
         "credential_status_interval must be at most #{ceiling} seconds"}
      ])
    else
      []
    end
  end

  defp categories(ctx) do
    categories = discovery!(ctx)["supported_categories"]

    Assert.check!(
      is_list(categories) and categories != [],
      "supported_categories must be a non-empty array"
    )

    categories |> Enum.flat_map(&category_problems/1) |> Enum.uniq() |> fail_unless_empty!()
  end

  defp category_problems(%{"id" => id} = category) when is_binary(id) do
    registered? = id in Context.registered_categories()

    failing([
      {is_binary(category["name"]) and is_binary(category["description"]),
       "#{id}: name and description are required"},
      {category["sensitivity"] in ~w(low medium high),
       "#{id}: sensitivity must be low, medium or high"},
      {registered? or absolute_uri?(id),
       "#{id}: neither a registered category nor an absolute URI"},
      {registered? or category["sensitivity"] != "low",
       "#{id}: a custom category is never Low sensitivity"},
      {if(registered?,
         do: Map.has_key?(category, "registry"),
         else: Map.has_key?(category, "definer")
       ), "#{id}: a registered category names its registry, a custom one its definer"}
    ])
  end

  defp category_problems(other),
    do: ["a category is not described as an object with an id: #{inspect(other)}"]

  defp absolute_uri?(value) do
    uri = URI.parse(value)
    is_binary(uri.scheme) and is_binary(uri.host) and uri.host != ""
  end

  defp durability(ctx) do
    durability = discovery!(ctx)["audit_durability"]
    Assert.check!(is_map(durability), "audit_durability must be an object")
    bounded = durability["bounded"] || %{}
    Assert.check!(is_map(bounded), "audit_durability.bounded must be an object")
    others = Map.keys(bounded) -- ["context.read"]

    Assert.check!(
      others == [],
      "a bounded window may only be declared for context.read, found #{inspect(others)}"
    )

    window = bounded["context.read"]

    Assert.check!(
      is_nil(window) or (is_integer(window) and window >= 0 and window <= 10_000),
      "the context.read window must be an integer of at most 10 000 ms, got #{inspect(window)}"
    )
  end

  defp pagination(ctx) do
    doc = discovery!(ctx)
    if "http" not in bindings(doc), do: Assert.not_applicable!("the HTTP Binding is not exposed")

    Assert.check!(
      get_in(doc, ["pagination", "audit"]) == "cursor",
      "pagination.audit must be \"cursor\""
    )
  end

  defp rate_limits(ctx),
    do: Assert.check!(is_map(discovery!(ctx)["rate_limits"]), "no rate_limits member")
end
