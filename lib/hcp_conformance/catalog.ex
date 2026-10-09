defmodule HcpConformance.Catalog do
  @moduledoc "Every check the suite knows, in run order."

  alias HcpConformance.Checks

  @modules [
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

  @doc "All checks, each tagged with its group."
  @spec all() :: [HcpConformance.Check.t()]
  def all do
    Enum.flat_map(@modules, fn module -> Enum.map(module.checks(), &%{&1 | group: module.group()}) end)
  end

  @doc "The group names, in run order."
  @spec groups() :: [String.t()]
  def groups, do: Enum.map(@modules, & &1.group())

  @doc "Checks narrowed to `groups` and/or check ids (`only`); nil means everything."
  @spec select([String.t()] | nil, [String.t()] | nil) :: [HcpConformance.Check.t()]
  def select(groups, only) do
    Enum.filter(all(), fn check ->
      (is_nil(groups) or check.group in groups) and (is_nil(only) or check.id in only)
    end)
  end
end
