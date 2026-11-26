defmodule Mix.Tasks.Hcp.Checks do
  @shortdoc "Prints the check catalogue as Markdown, or refreshes its documents"
  @moduledoc """
  The check catalogue as Markdown.

      mix hcp.checks --write                # refreshes docs/CHECKS.md and docs/CHECKS-v2.md
      mix hcp.checks                        # prints the v1 catalogue
      mix hcp.checks --spec-version 2.0     # prints the v2 catalogue

  Use `--write` to refresh the documents rather than redirecting the output:
  when the project has to compile first, Mix says so on standard output, and
  that line would end up in the document.
  """

  use Mix.Task
  use Boundary, classify_to: HcpConformance

  alias HcpConformance.{CLI, Spec}

  @documents %{"1.0" => "docs/CHECKS.md", "2.0" => "docs/CHECKS-v2.md"}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")

    {opts, _args, _invalid} =
      OptionParser.parse(argv, strict: [spec_version: :string, write: :boolean])

    if opts[:write] do
      for version <- Spec.versions() do
        path = Map.fetch!(@documents, version)
        File.write!(path, CLI.catalogue(version))
        Mix.shell().info("wrote #{path}")
      end
    else
      {:ok, version} = Spec.parse(opts[:spec_version])
      IO.write(CLI.catalogue(version || Spec.default()))
    end
  end
end
