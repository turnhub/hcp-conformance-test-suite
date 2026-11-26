defmodule Mix.Tasks.Hcp.Checks do
  @shortdoc "Prints the check catalogue as Markdown"
  @moduledoc """
  Prints the check catalogue. `mix hcp.checks > docs/CHECKS.md` refreshes the v1
  document, and `mix hcp.checks --spec-version 2.0 > docs/CHECKS-v2.md` the v2 one.
  """

  use Mix.Task
  use Boundary, classify_to: HcpConformance

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [spec_version: :string])
    {:ok, version} = HcpConformance.Spec.parse(opts[:spec_version])
    IO.write(HcpConformance.CLI.catalogue(version || HcpConformance.Spec.default()))
  end
end
