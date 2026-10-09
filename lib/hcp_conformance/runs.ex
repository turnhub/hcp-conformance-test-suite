defmodule HcpConformance.Runs do
  @moduledoc """
  Runs started from the web UI or the API.

  The app is stateless: a run lives in the process that asked for it (a
  LiveView's async task, or an API request) and its report goes back to that
  caller only. Nothing is stored. The one shared thing is a count of runs in
  progress, kept by registering each running process in a `Registry`, so a public
  instance can cap how many run at once.
  """

  alias HcpConformance.{Config, Runner, Settings}

  @registry HcpConformance.RunRegistry

  @doc """
  A run config from caller-supplied attributes (session or API body), with the
  private-network policy taken from the deployment, never from the caller.
  """
  @spec config(map()) :: {:ok, Config.t()} | {:error, String.t()}
  def config(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("allow_private", Settings.allow_private_targets?())
    |> Config.new()
  end

  @doc """
  Runs the suite in the calling process, unless the instance is already running
  as many as it allows. `opts` go to `HcpConformance.Runner.run/2`.
  """
  @spec run(Config.t(), keyword()) :: {:ok, map()} | {:error, :busy}
  def run(%Config{} = config, opts \\ []) do
    if Registry.count(@registry) >= Settings.max_concurrent_runs() do
      {:error, :busy}
    else
      {:ok, _owner} = Registry.register(@registry, :run, nil)

      try do
        {:ok, Runner.run(config, opts)}
      after
        Registry.unregister(@registry, :run)
      end
    end
  end
end
