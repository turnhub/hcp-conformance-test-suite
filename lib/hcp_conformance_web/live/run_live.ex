defmodule HcpConformanceWeb.RunLive do
  @moduledoc """
  Runs the suite against the target in the session and streams results as they
  arrive, grouped as the checkboxes group them. Each result folds in the HTTP
  exchanges its check made: method, URL, headers and bodies both ways, with
  credentials redacted. Setup and teardown traffic gets rows of its own, in the
  order it happened. A group opens when one of its results did not pass, and so
  does that result, on its exchanges.

  The run is a LiveView async task, linked to this page: closing the tab stops
  it. Its report lives in this process only, offered as a JSON download, and is
  gone when the page is.
  """

  use HcpConformanceWeb, :live_view

  alias HcpConformance.{Catalog, Config, Runs}
  alias HcpConformanceWeb.Exchanges

  @statuses [:pass, :fail, :warn, :skip, :error, :na]

  # Statuses that open a result, and its group.
  @problems [:fail, :warn, :error]

  @stat_labels [
    pass: "Passed",
    fail: "Failed",
    warn: "Warnings",
    skip: "Skipped",
    error: "Errors",
    na: "N/A"
  ]

  # Result filters: id, label, and the statuses shown (nil: everything).
  @filters [
    {"all", "All", nil},
    {"not-passed", "Not passed", ["fail", "warn", "error"]},
    {"passed", "Passed", ["pass"]},
    {"skipped", "Skipped or N/A", ["skip", "na"]}
  ]

  @impl true
  def mount(_params, %{"connection" => connection}, socket) when is_map(connection) do
    case Runs.config(connection) do
      {:ok, config} ->
        {:ok,
         socket
         |> assign(
           page_title: "Run",
           connection: connection,
           mode: Config.mode(config),
           groups: Catalog.groups(),
           group_counts: group_counts(),
           total_checks: length(Catalog.all()),
           stat_labels: @stat_labels,
           statuses: @statuses,
           filters: @filters
         )
         |> select(Catalog.groups())
         |> reset_run()}

      {:error, message} ->
        {:ok, socket |> put_flash(:error, message) |> redirect(to: ~p"/")}
    end
  end

  def mount(_params, _session, socket) do
    {:ok, socket |> put_flash(:info, "Connect to a target first.") |> redirect(to: ~p"/")}
  end

  defp reset_run(socket) do
    assign(socket,
      running: false,
      total: 0,
      done: 0,
      counts: Map.new(@statuses, &{&1, 0}),
      setup_notes: [],
      report: nil,
      # Exchanges of the check (or setup, or teardown) still running, by check
      # id, newest first; they join its row when it finishes.
      pending: %{},
      # The groups the run covers, in catalog order; their results as
      # {dom_id, result}, in the order they arrived; and their counts by status.
      run_groups: [],
      rows: %{},
      tally: %{},
      # Setup and teardown rows, in the order they happened.
      phases: [],
      # Setup's exchanges by id, kept for the results that cite them (the
      # discovery checks judge the document setup fetched).
      setup: %{},
      current: nil
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Conformance run
        <:subtitle><code class="break-all">{@connection["target"]}</code></:subtitle>
        <:actions>
          <.button href={~p"/session"} method="delete" id="disconnect" class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left-start-on-rectangle" /> Disconnect
          </.button>
        </:actions>
      </.header>

      <div id="mode" role="alert" class="alert">
        <span class="badge badge-primary">{@mode} mode</span>
        <span>{mode_note(@mode)}</span>
      </div>

      <.form for={@form} id="run-form" phx-change="select" phx-submit="run" class="card bg-base-200">
        <div class="card-body">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="card-title">What to check</h2>
            <div class="join">
              <.button
                type="button"
                id="select-all"
                phx-click="select_all"
                class="btn btn-sm join-item"
              >
                All
              </.button>
              <.button
                type="button"
                id="select-none"
                phx-click="select_none"
                class="btn btn-sm join-item"
              >
                None
              </.button>
            </div>
          </div>
          <div class="flex flex-wrap gap-2">
            <label
              :for={group <- @groups}
              for={"group-" <> group}
              class={[
                "btn btn-sm",
                if(group in @selected, do: "btn-primary btn-soft", else: "btn-ghost")
              ]}
            >
              <input type="hidden" name={"run[groups][#{group}]"} value="false" />
              <input
                type="checkbox"
                id={"group-" <> group}
                name={"run[groups][#{group}]"}
                value="true"
                checked={group in @selected}
                class="checkbox checkbox-xs"
              />
              {group}
              <span class="badge badge-sm badge-ghost">{@group_counts[group].checks}</span>
            </label>
          </div>
          <div class="card-actions items-center justify-between">
            <p id="selection">
              {@selection.checks} of {@total_checks} checks · {@selection.must} MUST · {@selection.should} SHOULD
              <span :if={@selection.checks not in [0, @total_checks]}>
                · not a conformance claim: only a full run is
              </span>
            </p>
            <.button
              variant="primary"
              id="run"
              disabled={@running or @selection.checks == 0}
              class="btn btn-primary"
            >
              <.icon :if={!@running} name="hero-play" />
              <span :if={@running} class="loading loading-spinner loading-sm"></span>
              {if @running, do: "Running…", else: "Run the suite"}
            </.button>
          </div>
        </div>
      </.form>

      <div :for={note <- @setup_notes} role="alert" class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" />
        <span>{note}</span>
      </div>

      <div :if={@running or @report} id="summary" class="card bg-base-200">
        <div class="card-body">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="card-title">
              <span :if={@running}>Running</span>
              <span :if={@report}>Verdict</span>
              <span
                :if={@report}
                id="verdict"
                data-verdict={@report.verdict}
                class={["badge badge-lg", verdict_class(@report.verdict)]}
              >
                {String.upcase(@report.verdict)}
              </span>
            </h2>
            <.button
              :if={@report}
              id="download-report"
              phx-click="download"
              phx-hook=".Download"
              class="btn btn-sm"
            >
              <.icon name="hero-arrow-down-tray" /> JSON report
            </.button>
          </div>

          <div :if={@running} id="progress-card">
            <progress
              id="progress"
              class="progress progress-primary"
              value={@done}
              max={max(@total, 1)}
            ></progress>
            <p>
              Ran {@done} of {@total} checks.
              <span :if={@current} id="current">
                Now <code>{@current.check_id}</code>, {requests(@current.requests)} so far.
              </span>
            </p>
          </div>

          <p :if={@report && @report.partial}>Selected checks only: not a conformance claim.</p>

          <div
            id="stats"
            class="stats grid-flow-row grid-cols-3 sm:grid-flow-col sm:grid-cols-none bg-base-100"
          >
            <div :for={{status, label} <- @stat_labels} id={"stat-#{status}"} class="stat">
              <div class="stat-title">{label}</div>
              <div class="stat-value">{@counts[status]}</div>
            </div>
          </div>

          <.list :if={@report}>
            <:item title="MUST">{summary(@report.summary.must)}</:item>
            <:item title="SHOULD">{summary(@report.summary.should)}</:item>
            <:item title="Capabilities">{Enum.join(@report.capabilities, ", ")}</:item>
          </.list>
        </div>
      </div>

      <div :if={@report} id="result-filter" class="join">
        <.button
          :for={{id, label, statuses} <- @filters}
          type="button"
          id={"filter-" <> id}
          phx-click={filter(id, statuses)}
          class={["btn btn-sm join-item", id == "all" && "btn-active"]}
        >
          {label}
        </.button>
      </div>

      <div id="results" class="space-y-2">
        <div :if={@phases != []} id="phases" class="space-y-2">
          <.row :for={{id, row} <- @phases} :key={id} id={id} result={row} />
        </div>
        <.group_section
          :for={group <- @run_groups}
          :key={group}
          group={group}
          rows={Map.get(@rows, group, [])}
          tally={Map.get(@tally, group, %{})}
          total={@group_counts[group].checks}
          running={@running}
          statuses={@statuses}
        />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Download">
        export default {
          mounted() {
            this.handleEvent("download-report", ({filename, content}) => {
              const url = URL.createObjectURL(new Blob([content], {type: "application/json"}))
              const link = document.createElement("a")
              link.href = url
              link.download = filename
              link.click()
              URL.revokeObjectURL(url)
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :group, :string, required: true
  attr :rows, :list, required: true
  attr :tally, :map, required: true
  attr :total, :integer, required: true
  attr :running, :boolean, required: true
  attr :statuses, :list, required: true

  # Open when a result did not pass. The server decides that on first render
  # only: after that, the person's own toggling wins, and a result that fails
  # later opens its group from the browser (see `row/1`).
  defp group_section(assigns) do
    assigns =
      assign(assigns,
        done: assigns.tally |> Map.values() |> Enum.sum(),
        problem: assigns.tally |> Map.keys() |> Enum.any?(&problem?/1)
      )

    ~H"""
    <details
      id={"results-" <> @group}
      data-group={@group}
      open={@problem}
      phx-mounted={JS.ignore_attributes("open")}
      class="collapse collapse-arrow border border-base-300 bg-base-100"
    >
      <summary class="collapse-title">
        <div class="flex flex-wrap items-center gap-2">
          <h3 class="card-title text-base">{@group}</h3>
          <span
            :for={status <- @statuses}
            :if={@tally[status]}
            class={["badge badge-sm", status_class(status)]}
          >
            {tally_label(status, @tally[status])}
          </span>
          <span :if={@running and @done < @total} class="badge badge-sm badge-ghost">
            {@done} of {@total}
          </span>
        </div>
      </summary>
      <div class="collapse-content space-y-2">
        <p :if={@rows == []}>Waiting for its first result.</p>
        <.row :for={{id, row} <- @rows} :key={id} id={id} result={row} />
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :result, :map, required: true

  defp row(assigns) do
    ~H"""
    <details
      id={@id}
      data-status={@result.status || "phase"}
      open={problem?(@result.status)}
      phx-mounted={row_mounted(@result.status)}
      class="collapse collapse-arrow bg-base-200"
    >
      <summary class="collapse-title">
        <div class="flex flex-wrap items-center gap-2">
          <span :if={@result.status} class={["badge", status_class(@result.status)]}>
            {status_label(@result.status)}
          </span>
          <span :if={!@result.status} class="badge badge-ghost">{String.upcase(@result.id)}</span>
          <code :if={@result.status} class="break-all">{@result.id}</code>
          <span :if={@result.section} class="badge badge-ghost badge-sm">§{@result.section}</span>
          <span :if={@result.level} class="badge badge-ghost badge-sm">
            {@result.level |> to_string() |> String.upcase()}
          </span>
          <span data-role="request-count" class="badge badge-ghost badge-sm">
            {requests(length(@result.exchanges))}
          </span>
        </div>
        <p>{@result.title}</p>
        <p :if={@result.message} role="alert" class="alert alert-soft">{@result.message}</p>
      </summary>
      <div class="collapse-content space-y-2">
        <p :if={@result.evidence == :run}>
          This check judges every response in the run: the requests are in the other rows.
        </p>
        <p :if={@result.exchanges == [] and @result.evidence != :run}>
          This check made no HTTP requests.
        </p>
        <Exchanges.exchange :for={exchange <- @result.exchanges} row={@id} exchange={exchange} />
      </div>
    </details>
    """
  end

  @impl true
  def handle_event("select", %{"run" => params}, socket) do
    selected = for {group, "true"} <- params["groups"] || %{}, do: group
    {:noreply, select(socket, selected)}
  end

  def handle_event("select_all", _params, socket),
    do: {:noreply, select(socket, Catalog.groups())}

  def handle_event("select_none", _params, socket), do: {:noreply, select(socket, [])}

  def handle_event("run", _params, %{assigns: %{running: true}} = socket), do: {:noreply, socket}

  def handle_event("run", params, socket) do
    groups = params |> get_in(["run", "groups"]) |> selected_groups()

    case Runs.config(Map.put(socket.assigns.connection, "groups", groups)) do
      {:ok, config} ->
        live_view = self()
        on_event = &send(live_view, {:run_event, &1})

        {:noreply,
         socket
         |> reset_run()
         |> assign(running: true, run_groups: run_groups(groups))
         |> start_async(:run, fn -> Runs.run(config, on_event: on_event) end)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("download", _params, %{assigns: %{report: %{} = report}} = socket) do
    filename = "hcp-conformance-#{Date.utc_today()}.json"

    {:noreply,
     push_event(socket, "download-report", %{filename: filename, content: Jason.encode!(report)})}
  end

  def handle_event("download", _params, socket), do: {:noreply, socket}

  # Every group ticked is no selection at all, so the verdict can be a claim.
  defp selected_groups(%{} = groups) do
    selected = for {group, "true"} <- groups, do: group
    if Enum.sort(selected) == Enum.sort(Catalog.groups()), do: nil, else: selected
  end

  defp selected_groups(_none), do: nil

  defp run_groups(nil), do: Catalog.groups()
  defp run_groups(groups), do: Enum.filter(Catalog.groups(), &(&1 in groups))

  @impl true
  def handle_info({:run_event, {:started, info}}, socket) do
    {:noreply,
     socket
     |> assign(total: info.total, setup_notes: info.setup_notes)
     |> insert_phases()}
  end

  def handle_info({:run_event, {:exchange, exchange}}, socket) do
    check_id = exchange.check_id || "setup"

    pending =
      Map.update(
        socket.assigns.pending,
        check_id,
        [Exchanges.entry(exchange)],
        &[Exchanges.entry(exchange) | &1]
      )

    {:noreply,
     assign(socket,
       pending: pending,
       current: %{check_id: check_id, requests: length(pending[check_id])}
     )}
  end

  def handle_info({:run_event, {:result, result}}, socket) do
    socket = insert_phases(socket)
    {own, pending} = Map.pop(socket.assigns.pending, result.id, [])
    own = Enum.reverse(own)
    own_ids = MapSet.new(own, & &1.id)

    cited =
      for id <- result.exchanges,
          not MapSet.member?(own_ids, id),
          entry = socket.assigns.setup[id],
          do: entry

    row = {dom_id(result.id), %{result | exchanges: cited ++ own}}

    {:noreply,
     socket
     |> assign(pending: pending, current: nil)
     |> update(:done, &(&1 + 1))
     |> update(:counts, &Map.update!(&1, result.status, fn count -> count + 1 end))
     |> update(:rows, &Map.update(&1, result.group, [row], fn rows -> rows ++ [row] end))
     |> update(:tally, &tally(&1, result.group, result.status))}
  end

  def handle_info({:run_event, {:finished, _report}}, socket),
    do: {:noreply, insert_phases(socket)}

  @impl true
  def handle_async(:run, {:ok, {:ok, report}}, socket) do
    {:noreply,
     assign(socket, running: false, current: nil, report: report, setup_notes: report.setup_notes)}
  end

  def handle_async(:run, {:ok, {:error, :busy}}, socket) do
    {:noreply,
     socket
     |> assign(running: false)
     |> put_flash(:error, "The suite is busy with other runs. Try again in a minute.")}
  end

  def handle_async(:run, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(running: false) |> put_flash(:error, "The run stopped: #{inspect(reason)}")}
  end

  @phases %{
    "setup" => "Discovery, and the subject and grants the run works with",
    "teardown" => "Disposing of the subject, or deleting the entries the run created"
  }

  # Setup and teardown traffic finished before the next check reports, so their
  # rows go in then, keeping the list in the order things happened.
  defp insert_phases(socket), do: Enum.reduce(["setup", "teardown"], socket, &insert_phase/2)

  defp insert_phase(phase, socket) do
    case Map.pop(socket.assigns.pending, phase) do
      {nil, _pending} ->
        socket

      {exchanges, pending} ->
        exchanges = Enum.reverse(exchanges)

        socket
        |> assign(pending: pending)
        |> remember_setup(phase, exchanges)
        |> update(:phases, &(&1 ++ [{dom_id(phase), phase_row(phase, exchanges)}]))
    end
  end

  defp remember_setup(socket, "setup", exchanges),
    do: assign(socket, setup: Map.new(exchanges, &{&1.id, &1}))

  defp remember_setup(socket, _phase, _exchanges), do: socket

  defp phase_row(phase, exchanges) do
    %{
      id: phase,
      title: @phases[phase],
      status: nil,
      message: nil,
      section: nil,
      level: nil,
      evidence: :own,
      exchanges: exchanges
    }
  end

  defp select(socket, selected) do
    counts = socket.assigns.group_counts

    selection =
      Enum.reduce(selected, %{checks: 0, must: 0, should: 0}, fn group, acc ->
        Map.merge(acc, counts[group], fn _key, sum, count -> sum + count end)
      end)

    form =
      to_form(%{"groups" => Map.new(Catalog.groups(), &{&1, to_string(&1 in selected)})},
        as: :run
      )

    assign(socket, selected: selected, selection: selection, form: form)
  end

  defp group_counts do
    Catalog.all()
    |> Enum.group_by(& &1.group)
    |> Map.new(fn {group, checks} ->
      {group,
       %{
         checks: length(checks),
         must: Enum.count(checks, &(&1.level == :must)),
         should: Enum.count(checks, &(&1.level == :should))
       }}
    end)
  end

  @spec dom_id(String.t()) :: String.t()
  defp dom_id(id), do: "result-" <> String.replace(id, ".", "-")

  @spec tally(map(), String.t(), atom()) :: map()
  defp tally(tally, group, status) do
    Map.update(tally, group, %{status => 1}, &Map.update(&1, status, 1, fn n -> n + 1 end))
  end

  # A row that did not pass opens the group it lands in, however that group
  # was left; every row keeps its own open state through later updates.
  defp row_mounted(status) when status in @problems do
    "open"
    |> JS.ignore_attributes()
    |> JS.set_attribute({"open", ""}, to: {:closest, "[data-group]"})
  end

  defp row_mounted(_status), do: JS.ignore_attributes("open")

  @spec problem?(atom()) :: boolean()
  defp problem?(status), do: status in @problems

  defp tally_label(:pass, count), do: "#{count} passed"
  defp tally_label(:fail, count), do: "#{count} failed"
  defp tally_label(:skip, count), do: "#{count} skipped"
  defp tally_label(:na, count), do: "#{count} N/A"
  defp tally_label(:warn, 1), do: "1 warning"
  defp tally_label(:warn, count), do: "#{count} warnings"
  defp tally_label(:error, 1), do: "1 error"
  defp tally_label(:error, count), do: "#{count} errors"

  defp mode_note(:hook),
    do:
      "The suite creates a fresh subject through the conformance hook and issues itself the grants each check needs, so every check can run."

  defp mode_note(:static),
    do:
      "The suite uses the tokens you gave. Checks that need the hook to issue grants are skipped."

  defp mode_note(:anonymous),
    do: "No credentials: only checks that need none can run; the rest are skipped."

  # Shows the results with these statuses, client-side; the groups stay.
  defp filter(id, statuses) do
    js =
      JS.remove_class("btn-active", to: "#result-filter .btn")
      |> JS.add_class("btn-active", to: "#filter-" <> id)

    case statuses do
      nil ->
        JS.show(js, to: "#results [data-status]")

      statuses ->
        js
        |> JS.hide(to: "#results [data-status]")
        |> JS.show(to: Enum.map_join(statuses, ", ", &"#results [data-status=#{&1}]"))
    end
  end

  defp requests(1), do: "1 request"
  defp requests(count), do: "#{count} requests"

  defp summary(counts) do
    Enum.map_join(@statuses, ", ", fn status ->
      "#{counts[status]} #{status_label(status) |> String.downcase()}"
    end)
  end

  defp status_label(:na), do: "N/A"
  defp status_label(status), do: status |> to_string() |> String.upcase()

  defp status_class(:pass), do: "badge-success"
  defp status_class(:fail), do: "badge-error"
  defp status_class(:error), do: "badge-error"
  defp status_class(:warn), do: "badge-warning"
  defp status_class(_status), do: "badge-ghost"

  defp verdict_class("pass"), do: "badge-success"
  defp verdict_class("fail"), do: "badge-error"
  defp verdict_class(_incomplete), do: "badge-warning"
end
