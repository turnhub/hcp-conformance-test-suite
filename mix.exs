defmodule HcpConformance.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :hcp_conformance,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      escript: [main_module: HcpConformance.CLI, name: "hcp_conformance", app: nil],
      releases: [hcp_conformance: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {HcpConformance.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"}
    ]
  end
end
