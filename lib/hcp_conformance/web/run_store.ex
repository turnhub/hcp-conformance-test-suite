defmodule HcpConformance.Web.RunStore do
  @moduledoc """
  Runs started from the web UI or API: their public config, live progress and
  final report. In memory (ETS), newest 200 kept, so a hosted instance needs no
  database and holds no credentials: configs are stored without their secrets.
  """

  use GenServer

  @table __MODULE__
  @keep 200

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Registers a new run; returns its id."
  @spec create(map()) :: String.t()
  def create(public_config) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    run = %{
      id: id,
      status: :queued,
      config: public_config,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      total: nil,
      results: [],
      setup_notes: [],
      report: nil,
      error: nil
    }

    :ets.insert(@table, {id, run})
    prune()
    id
  end

  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, run}] -> run
      [] -> nil
    end
  end

  @spec update(String.t(), (map() -> map())) :: :ok
  def update(id, fun) do
    case get(id) do
      nil -> :ok
      run -> :ets.insert(@table, {id, fun.(run)}) && :ok
    end
  end

  @doc "How many runs are queued or running."
  @spec active_count() :: non_neg_integer()
  def active_count do
    :ets.foldl(
      fn {_id, run}, acc -> if run.status in [:queued, :running], do: acc + 1, else: acc end,
      0,
      @table
    )
  end

  defp prune do
    runs = :ets.tab2list(@table)

    if length(runs) > @keep do
      runs
      |> Enum.sort_by(fn {_id, run} -> run.created_at end)
      |> Enum.take(length(runs) - @keep)
      |> Enum.each(fn {id, _run} -> :ets.delete(@table, id) end)
    end
  end
end
