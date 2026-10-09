defmodule Mix.Tasks.Hcp.Server do
  @shortdoc "Serves the web runner and reference implementation locally"
  @moduledoc """
  Starts the hosted runner on http://localhost:4000 (or `PORT`), with the
  reference HCP implementation at `/reference`. This is not a Phoenix app, so
  there is no `phx.server`; this task is its equivalent.

      mix hcp.server
      PORT=4100 mix hcp.server

  Outside production, private and loopback targets are allowed by default, so a
  local runner can test an implementation on localhost. Set
  `ALLOW_PRIVATE_TARGETS=false` to behave like a public deployment.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    # config/runtime.exs reads SERVE when the app is configured, so it has to be
    # set before `run` loads the config.
    System.put_env("SERVE", "true")
    port = System.get_env("PORT", "4000")

    Mix.shell().info(
      "HCP conformance suite on http://localhost:#{port} (reference implementation at /reference)"
    )

    Mix.Tasks.Run.run(["--no-halt" | args])
  end
end
