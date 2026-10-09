defmodule HcpConformance.Runner do
  @moduledoc """
  Runs the selected checks against a target, one at a time, and builds the report.

  Each check runs in its own task with a timeout, tagged so the transcript knows
  which exchanges it made. Checks run sequentially on purpose: several observe the
  audit log, and concurrent writes from other checks would make "exactly one event"
  assertions meaningless.
  """

  alias HcpConformance.{
    Catalog,
    Check,
    Config,
    Context,
    Failure,
    HTTP,
    NotApplicable,
    Report,
    Skip,
    Transcript
  }

  @transports [:rest, :mcp]

  @type event :: {:started, map()} | {:result, map()} | {:finished, map()}

  @doc """
  Runs a conformance run. `opts[:on_event]` receives progress events
  (`{:started, info}`, `{:result, result}`, `{:finished, report}`).
  """
  @spec run(Config.t(), keyword()) :: map()
  def run(%Config{} = config, opts \\ []) do
    notify = Keyword.get(opts, :on_event, fn _event -> :ok end)
    started_at = DateTime.utc_now()
    ctx = Context.start(config)
    checks = Catalog.select(config.groups, config.only)
    {main, post} = Enum.split_with(checks, &(&1.phase == :main))

    notify.(
      {:started,
       %{total: length(checks), capabilities: MapSet.to_list(ctx.capabilities), setup_notes: ctx.setup_notes}}
    )

    main_results = Enum.map(main, &run_and_notify(ctx, &1, notify))
    Context.finish(ctx)
    post_results = Enum.map(post, &run_and_notify(ctx, &1, notify))

    report = Report.build(ctx, main_results ++ post_results, started_at)
    Agent.stop(ctx.transcript)
    Agent.stop(ctx.state)
    notify.({:finished, report})
    report
  end

  defp run_and_notify(ctx, check, notify) do
    result = run_check(ctx, check)
    notify.({:result, result})
    result
  end

  @spec run_check(Context.t(), Check.t()) :: map()
  defp run_check(ctx, %Check{} = check) do
    base = %{
      id: check.id,
      section: check.section,
      level: check.level,
      title: check.title,
      group: check.group,
      exchanges: []
    }

    case Enum.reject(check.requires, &Context.has?(ctx, &1)) do
      [] ->
        started = System.monotonic_time(:millisecond)
        {status, message} = execute(ctx, check)

        exchanges =
          ctx.transcript
          |> Transcript.exchanges()
          |> Enum.filter(&(&1.check_id == check.id))
          |> Enum.map(& &1.id)

        Map.merge(base, %{
          status: status,
          message: message && Transcript.redact(ctx.transcript, message),
          duration_ms: System.monotonic_time(:millisecond) - started,
          exchanges: exchanges
        })

      missing ->
        # A transport the target does not declare makes the check inapplicable;
        # anything else missing means it could not run.
        status = if Enum.all?(missing, &(&1 in @transports)), do: :na, else: :skip
        Map.merge(base, %{status: status, message: "needs " <> describe(missing), duration_ms: 0})
    end
  end

  defp execute(ctx, check) do
    task =
      Task.async(fn ->
        Process.put(:hcp_check_id, check.id)
        outcome(ctx, check)
      end)

    case Task.yield(task, ctx.config.check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:error, "the check crashed: " <> inspect(reason)}
      nil -> {:error, "the check timed out after #{ctx.config.check_timeout_ms} ms"}
    end
  end

  defp outcome(ctx, check) do
    case check.run.(ctx) do
      {:skip, reason} -> {:skip, reason}
      _ok -> {:pass, nil}
    end
  rescue
    error in Failure ->
      {if(check.level == :must, do: :fail, else: :warn), error.message}

    error in Skip ->
      {:skip, error.message}

    error in NotApplicable ->
      {:na, error.message}

    error in HTTP.TransportError ->
      {:error, "transport error: " <> error.message}

    error ->
      {:error, ("suite error: " <> Exception.format(:error, error, __STACKTRACE__)) |> String.slice(0, 1_500)}
  end

  defp describe(missing) do
    Enum.map_join(missing, ", ", fn
      :person -> "a person credential"
      :agent -> "an agent credential with read and write on the primary category"
      :hook -> "the conformance hook"
      :rest -> "the REST transport"
      :mcp -> "the MCP transport"
      :second_category -> "a second supported category"
      other -> to_string(other)
    end)
  end
end
