defmodule HcpConformance do
  @moduledoc """
  A standalone conformance suite for the Human Context Protocol (HCP) v1,
  draft 4.

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
  hook, and docs/CHECKS.md for every check and the section it tests.
  """

  # The suite: checks, runner, reports. It knows nothing of the web layer or the
  # reference implementation, which it tests like any other target.
  use Boundary, deps: [], exports: [Catalog, CLI, Config, Memory, OpenAI, Runs, Settings]

  alias HcpConformance.{Config, Runner}

  @doc "Runs the suite. `opts[:on_event]` receives progress events."
  @spec run(map() | keyword(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(attrs, opts \\ []) do
    with {:ok, config} <- Config.new(attrs) do
      {:ok, Runner.run(config, opts)}
    end
  end
end
