defmodule HcpConformance.Application do
  @moduledoc """
  Starts the run supervisor and run store always, and the web server with its
  reference implementation when `serve` is set (the default for releases).
  """

  use Application

  @impl Application
  def start(_type, _args) do
    serve = Application.get_env(:hcp_conformance, :serve, false)

    children =
      [
        {Task.Supervisor, name: HcpConformance.RunSupervisor},
        HcpConformance.Web.RunStore,
        {HcpConformance.Reference.Store, name: HcpConformance.Reference.DefaultStore}
      ] ++
        if serve do
          port = Application.get_env(:hcp_conformance, :port, 4000)
          [{Bandit, plug: HcpConformance.Web.Endpoint, port: port, ip: {0, 0, 0, 0}}]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: HcpConformance.Supervisor)
  end
end
