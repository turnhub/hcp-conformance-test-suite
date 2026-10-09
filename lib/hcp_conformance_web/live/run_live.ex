defmodule HcpConformanceWeb.RunLive do
  @moduledoc """
  Runs the suite against the target in the session and streams results as they
  arrive.

  The run is a LiveView async task, linked to this page: closing the tab stops
  it. Its report lives in this process only, offered as a JSON download, and is
  gone when the page is.
  """

  use HcpConformanceWeb, :live_view

  alias HcpConformance.{Catalog, Config, Runs}

  @statuses [:pass, :fail, :warn, :skip, :error, :na]

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
           form: to_form(%{"groups" => Map.new(Catalog.groups(), &{&1, "true"})}, as: :run)
         )
         |> reset_run()
         |> stream_configure(:results, dom_id: &("result-" <> String.replace(&1.id, ".", "-")))
         |> stream(:results, [])}

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
      findings: []
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Conformance run
        <:subtitle>{@connection["target"]} · {@mode} mode</:subtitle>
        <:actions>
          <.button href={~p"/session"} method="delete" id="disconnect">Disconnect</.button>
        </:actions>
      </.header>

      <.form for={@form} id="run-form" phx-submit="run">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Groups</legend>
          <.input
            :for={group <- @groups}
            type="checkbox"
            id={"group-#{group}"}
            name={"run[groups][#{group}]"}
            label={group}
            value={@form.params["groups"][group]}
          />
        </fieldset>
        <.button variant="primary" id="run" disabled={@running}>
          {if @running, do: "Running…", else: "Run the suite"}
        </.button>
      </.form>

      <div :if={@running} id="progress-card" class="card bg-base-200">
        <div class="card-body">
          <p>Ran {@done} of {@total} checks.</p>
          <progress id="progress" class="progress progress-primary" value={@done} max={max(@total, 1)}></progress>
        </div>
      </div>

      <div :if={@report} id="summary" class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">
            Verdict
            <span
              id="verdict"
              data-verdict={@report.verdict}
              class={["badge badge-lg", verdict_class(@report.verdict)]}
            >
              {String.upcase(@report.verdict)}
            </span>
          </h2>
          <p :if={@report.partial}>Selected checks only: not a conformance claim.</p>
          <.list>
            <:item title="MUST">{summary(@report.summary.must)}</:item>
            <:item title="SHOULD">{summary(@report.summary.should)}</:item>
            <:item title="Capabilities">{Enum.join(@report.capabilities, ", ")}</:item>
          </.list>
          <div class="card-actions">
            <.button id="download-report" phx-click="download" phx-hook=".Download">
              <.icon name="hero-arrow-down-tray" /> Download the JSON report
            </.button>
          </div>
        </div>
      </div>

      <div :for={note <- @setup_notes} role="alert" class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" />
        <span>{note}</span>
      </div>

      <div class="overflow-x-auto">
        <.table id="results" rows={@streams.results}>
          <:col :let={{_id, result}} label="Result">
            <span class={["badge", status_class(result.status)]}>{status_label(result.status)}</span>
          </:col>
          <:col :let={{_id, result}} label="Check">
            <code>{result.id}</code>
            <p>{result.title}</p>
            <p :if={result.message}>{result.message}</p>
          </:col>
          <:col :let={{_id, result}} label="Section">§{result.section}</:col>
          <:col :let={{_id, result}} label="Level">
            {result.level |> to_string() |> String.upcase()}
          </:col>
        </.table>
      </div>

      <section :if={@findings != []} id="findings">
        <.header>
          Findings
          <:subtitle>The HTTP exchanges behind each failure, warning and error.</:subtitle>
        </.header>
        <div
          :for={finding <- @findings}
          id={"finding-" <> String.replace(finding.id, ".", "-")}
          class="collapse collapse-arrow bg-base-200"
        >
          <input type="checkbox" />
          <div class="collapse-title">
            <code>{finding.id}</code> {finding.message}
          </div>
          <div class="collapse-content">
            <div :for={exchange <- finding.exchanges}>
              <p>
                <code>{exchange.method} {exchange.url} → {exchange.status || "no response"}</code>
              </p>
              <pre :if={exchange.request_body} class="whitespace-pre-wrap">{exchange.request_body}</pre>
              <pre class="whitespace-pre-wrap">{exchange.response_body || exchange.error}</pre>
            </div>
          </div>
        </div>
      </section>

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

  @impl true
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
         |> assign(running: true, form: to_form(params["run"] || %{}, as: :run))
         |> stream(:results, [], reset: true)
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

  @impl true
  def handle_info({:run_event, {:started, info}}, socket) do
    {:noreply, assign(socket, total: info.total, setup_notes: info.setup_notes)}
  end

  def handle_info({:run_event, {:result, result}}, socket) do
    {:noreply,
     socket
     |> update(:done, &(&1 + 1))
     |> update(:counts, &Map.update!(&1, result.status, fn count -> count + 1 end))
     |> stream_insert(:results, result)}
  end

  def handle_info({:run_event, {:finished, _report}}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:run, {:ok, {:ok, report}}, socket) do
    {:noreply,
     assign(socket,
       running: false,
       report: report,
       setup_notes: report.setup_notes,
       findings: findings(report)
     )}
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

  # Non-passing results with the exchanges behind them, resolved from the
  # transcript once the run is over.
  defp findings(report) do
    exchanges = Map.new(report.transcript, &{&1.id, &1})

    for result <- report.results, result.status in [:fail, :warn, :error] do
      %{
        id: result.id,
        message: result.message,
        exchanges: Enum.map(result.exchanges, &exchanges[&1]) |> Enum.reject(&is_nil/1)
      }
    end
  end

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
