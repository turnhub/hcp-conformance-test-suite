defmodule HcpConformance.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Starts the suite's processes, the reference implementation and the web layer,
  # so it alone may name all three.
  use Boundary,
    top_level?: true,
    deps: [HcpConformance, HcpConformance.Reference, HcpConformanceWeb]

  @impl true
  def start(_type, _args) do
    children = [
      HcpConformanceWeb.Telemetry,
      {Phoenix.PubSub, name: HcpConformance.PubSub},
      # Each running suite registers here, so the number running at once can be capped.
      {Registry, keys: :duplicate, name: HcpConformance.RunRegistry},
      # The reference HCP implementations served at /reference (v1) and
      # /reference/hcp-v2 (v2) keep their synthetic subjects in memory.
      {HcpConformance.Reference.Store, name: HcpConformance.Reference.DefaultStore},
      Supervisor.child_spec(
        {HcpConformance.Reference.Store, name: HcpConformance.Reference.DefaultStoreV2},
        id: HcpConformance.Reference.DefaultStoreV2
      ),
      HcpConformanceWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HcpConformance.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HcpConformanceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
