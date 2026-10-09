defmodule Mix.Tasks.Hcp.Checks do
  @shortdoc "Prints the check catalogue as Markdown"
  @moduledoc "Prints the check catalogue; `mix hcp.checks > docs/CHECKS.md` refreshes the document."

  use Mix.Task
  use Boundary, classify_to: HcpConformance

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("compile")
    IO.write(HcpConformance.CLI.catalogue())
  end
end
