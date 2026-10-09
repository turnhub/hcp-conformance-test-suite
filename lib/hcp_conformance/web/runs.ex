defmodule HcpConformance.Web.Runs do
  @moduledoc "Starts runs in the background for the web UI and API, within the concurrency limit."

  alias HcpConformance.{Config, Runner}
  alias HcpConformance.Web.RunStore

  @doc "Validates the submitted config and starts the run. Returns the run id."
  @spec start(map()) :: {:ok, String.t()} | {:error, :busy | String.t()}
  def start(params) do
    allow_private = Application.get_env(:hcp_conformance, :allow_private_targets, false)
    limit = Application.get_env(:hcp_conformance, :max_concurrent_runs, 4)

    with {:ok, config} <- Config.new(Map.put(params, "allow_private", allow_private)),
         true <- RunStore.active_count() < limit || {:error, :busy} do
      id = RunStore.create(Config.public(config))
      {:ok, _pid} = Task.Supervisor.start_child(HcpConformance.RunSupervisor, fn -> execute(id, config) end)
      {:ok, id}
    end
  end

  defp execute(id, config) do
    RunStore.update(id, &%{&1 | status: :running})

    on_event = fn
      {:started, info} -> RunStore.update(id, &%{&1 | total: info.total, setup_notes: info.setup_notes})
      {:result, result} -> RunStore.update(id, &%{&1 | results: &1.results ++ [result]})
      {:finished, report} -> RunStore.update(id, &%{&1 | status: :finished, report: report})
    end

    Runner.run(config, on_event: on_event)
  rescue
    error -> RunStore.update(id, &%{&1 | status: :failed, error: Exception.message(error)})
  end
end
