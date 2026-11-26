defmodule HcpConformance.Catalog do
  @moduledoc """
  Every check the suite knows, in run order, for each specification version
  (`HcpConformance.Spec`). Without a version, the functions answer for v1.
  """

  alias HcpConformance.{Checks, Spec, V2}

  @v1 [
    Checks.Discovery,
    Checks.Transport,
    Checks.Entries,
    Checks.Idempotency,
    Checks.Search,
    Checks.Conflicts,
    Checks.Grants,
    Checks.Audit,
    Checks.Export,
    Checks.Mcp,
    Checks.Responses
  ]

  @v2 [
    V2.Checks.Discovery,
    V2.Checks.Transport,
    V2.Checks.Entries,
    V2.Checks.Idempotency,
    V2.Checks.Query,
    V2.Checks.Grants,
    V2.Checks.Governance,
    V2.Checks.Rules,
    V2.Checks.Audit,
    V2.Checks.Export,
    V2.Checks.Responses
  ]

  defp modules("2.0"), do: @v2
  defp modules(_v1), do: @v1

  @doc "All checks of a version, each tagged with its group."
  @spec all(Spec.version()) :: [HcpConformance.Check.t()]
  def all(version \\ Spec.default()) do
    Enum.flat_map(modules(version), fn module ->
      Enum.map(module.checks(), &%{&1 | group: module.group()})
    end)
  end

  @doc "The group names of a version, in run order."
  @spec groups(Spec.version()) :: [String.t()]
  def groups(version \\ Spec.default()), do: Enum.map(modules(version), & &1.group())

  @doc "A version's checks narrowed to `groups` and/or check ids (`only`); nil means everything."
  @spec select(Spec.version(), [String.t()] | nil, [String.t()] | nil) ::
          [HcpConformance.Check.t()]
  def select(version, groups, only) do
    Enum.filter(all(version), fn check ->
      (is_nil(groups) or check.group in groups) and (is_nil(only) or check.id in only)
    end)
  end
end
