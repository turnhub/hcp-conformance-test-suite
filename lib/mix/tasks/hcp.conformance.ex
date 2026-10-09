defmodule Mix.Tasks.Hcp.Conformance do
  @shortdoc "Runs the HCP conformance suite against a target"
  @moduledoc """
  Runs the HCP conformance suite. Flags and exit status as for
  `HcpConformance.CLI`:

      mix hcp.conformance --target https://vault.example.com --hook-url … --hook-secret …
  """

  use Mix.Task
  use Boundary, classify_to: HcpConformance

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    status = HcpConformance.CLI.run(argv)
    if status != 0, do: exit({:shutdown, status})
  end
end
