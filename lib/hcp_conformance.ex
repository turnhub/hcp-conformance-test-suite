defmodule HcpConformance do
  @moduledoc """
  A standalone conformance suite for the Human Context Protocol (HCP): v1
  (1.0-draft-4) and v2 (2.0-draft-3). `HcpConformance.Spec` names the versions.

  Point it at any HCP implementation reachable over HTTP:

      {:ok, report} =
        HcpConformance.run(%{
          target: "https://vault.example.com",
          hook_url: "https://vault.example.com/conformance-hook",
          hook_secret: "…"
        })

      report.verdict
      #=> "pass" | "fail" | "incomplete"

  See `HcpConformance.Config` for the run modes, docs/HOOK.md for the conformance
  hook, and docs/CHECKS.md (v1) and docs/CHECKS-v2.md (v2) for every check and
  the section it tests.
  """

  # The suite: checks, runner, reports. It knows nothing of the web layer or the
  # reference implementation, which it tests like any other target.
  use Boundary, deps: [], exports: [Assistants, Catalog, CLI, Config, Runs, Settings, Spec, Vault]

  alias HcpConformance.{Config, Runner}

  @doc "Runs the suite. `opts[:on_event]` receives progress events."
  @spec run(map() | keyword(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(attrs, opts \\ []) do
    with {:ok, config} <- Config.new(attrs) do
      {:ok, Runner.run(config, opts)}
    end
  end
end
