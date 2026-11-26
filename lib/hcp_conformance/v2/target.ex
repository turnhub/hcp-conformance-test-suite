defmodule HcpConformance.V2.Target do
  @moduledoc """
  What a v2 run takes from a target's discovery document (§19): the HTTP
  Binding's endpoints, the bindings exposed, the categories to work in, and the
  `context.read` durability window. Also the shape of a grant request to the
  conformance hook for v2 (docs/HOOK.md), and of the grant lists it reads back.
  """

  alias HcpConformance.Context

  @purpose "https://conformance.hcp.example/purposes/conformance-check"
  @other_purpose "https://conformance.hcp.example/purposes/not-approved"
  @operator %{"id" => "https://conformance.hcp.example", "name" => "HCP conformance suite"}

  @doc "The purpose code every default grant of the suite approves."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "A purpose code no grant of the suite approves."
  @spec other_purpose() :: String.t()
  def other_purpose, do: @other_purpose

  @doc "The Client Operator the suite's clients are registered under."
  @spec operator() :: map()
  def operator, do: @operator

  @doc "Endpoints, bindings and the read window, with the binding's paths as defaults (§9.2)."
  @spec resolve(map(), HcpConformance.Config.t()) :: map()
  def resolve(discovery, config) do
    base = config.target
    bindings = discovery["bindings"]
    entries = endpoint(discovery, "entries_endpoint", base <> "/v2/entries")

    %{
      http?: not is_list(bindings) or "http" in bindings,
      mcp?: is_list(bindings) and "mcp" in bindings,
      read_window_ms: read_window(discovery),
      endpoints: %{
        discovery: config.discovery_url || base <> "/.well-known/hcp-configuration",
        entries: entries,
        query: entries <> "/query",
        grants: endpoint(discovery, "grants_endpoint", base <> "/v2/grants"),
        audit: endpoint(discovery, "audit_endpoint", base <> "/v2/audit"),
        export: endpoint(discovery, "export_endpoint", base <> "/v2/export"),
        rules: endpoint(discovery, "rules_endpoint", base <> "/v2/rules"),
        directives: endpoint(discovery, "directives_endpoint", base <> "/v2/directives"),
        shares: endpoint(discovery, "shares_endpoint", base <> "/v2/shares"),
        # Published only where the MCP Binding runs over Streamable HTTP (§19.3).
        mcp: endpoint(discovery, "mcp_endpoint", nil)
      }
    }
  end

  defp endpoint(discovery, member, default) do
    case discovery[member] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _absent -> default
    end
  end

  defp read_window(discovery) do
    case get_in(discovery, ["audit_durability", "bounded", "context.read"]) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> 0
    end
  end

  @doc "The registered categories among the described categories a target holds."
  @spec registered([term()], [String.t()]) :: [String.t()]
  def registered(described, registry) do
    for %{"id" => id} <- described, id in registry, do: id
  end

  @doc """
  The body members that say what a grant authorizes. `opts`: `:access` (whole
  details), or `:actions`, `:categories`, `:purposes` (codes), `:narrowed_to`
  and `:onward_sharing` (the election, `%{}` for any organization) for a single
  detail; `:operator` for a Client Operator other than the suite's.
  """
  @spec grant_attrs(Context.t(), keyword()) :: map()
  def grant_attrs(ctx, opts) do
    access =
      Keyword.get_lazy(opts, :access, fn ->
        detail = %{
          "actions" => Keyword.get(opts, :actions, ["read"]),
          "categories" => Keyword.get(opts, :categories, [ctx.primary_category]),
          "purposes" => opts |> Keyword.get(:purposes, [@purpose]) |> Enum.map(&describe/1)
        }

        [
          detail
          |> put_some("narrowedTo", opts[:narrowed_to])
          |> put_some("onwardSharing", opts[:onward_sharing])
        ]
      end)

    %{"access" => access, "operator" => Keyword.get(opts, :operator, @operator)}
  end

  defp describe(code), do: %{"code" => code, "description" => "HCP conformance run"}

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  @doc "Scope strings for the registered categories and read or write actions of `access` (§6.1.1)."
  @spec scopes([map()]) :: [String.t()]
  def scopes(access) do
    for detail <- access,
        category <- detail["categories"],
        action <- detail["actions"],
        action in ["read", "write"],
        uniq: true,
        do: "hcp:#{category}:#{action}"
  end

  @doc """
  The grant objects in a `GET /v2/grants` body. The binding does not name the
  member that holds them (§9.4.6), and the published schema for a client reading
  its own grant is the bare grant object, so both shapes are read.
  """
  @spec grants(term()) :: [map()]
  def grants(%{"grants" => grants}) when is_list(grants), do: Enum.filter(grants, &is_map/1)
  def grants(%{"grantId" => _id} = grant), do: [grant]
  def grants(_body), do: []
end
