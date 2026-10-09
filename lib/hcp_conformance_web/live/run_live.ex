defmodule HcpConformanceWeb.RunLive do
  @moduledoc """
  Runs the suite against the target in the session and streams results as they
  arrive. Each result folds in the HTTP exchanges its check made: method, URL,
  headers and bodies both ways, with credentials redacted. Setup and teardown
  traffic gets rows of its own, in the order it happened, and a result that did
  not pass opens on its exchanges.

  The run is a LiveView async task, linked to this page: closing the tab stops
  it. Its report lives in this process only, offered as a JSON download, and is
  gone when the page is.
  """

  use HcpConformanceWeb, :live_view

  alias HcpConformance.{Catalog, Config, Runs}

  @statuses [:pass, :fail, :warn, :skip, :error, :na]

  # Characters of each body shown in the live log; the JSON report keeps up to
  # 16 KB of each.
  @live_body_chars 8_000

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
      # Exchanges of the check (or setup, or teardown) still running, by check
      # id, newest first; they join its row when it finishes.
      pending: %{},
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
          <p :if={@current} id="current">
            Now: <code>{@current.check_id}</code>, {requests(@current.requests)} so far.
          </p>
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

      <div id="results" phx-update="stream" class="space-y-2">
        <details
          :for={{dom_id, result} <- @streams.results}
          id={dom_id}
          open={result.status in [:fail, :warn, :error]}
          class="collapse collapse-arrow bg-base-200"
        >
          <summary class="collapse-title">
            <span :if={result.status} class={["badge", status_class(result.status)]}>
              {status_label(result.status)}
            </span>
            <span :if={!result.status} class="badge badge-ghost">{String.upcase(result.id)}</span>
            <code :if={result.status}>{result.id}</code>
            <span :if={result.section} class="badge badge-ghost">§{result.section}</span>
            <span :if={result.level} class="badge badge-ghost">
              {result.level |> to_string() |> String.upcase()}
            </span>
            <span data-role="request-count" class="badge badge-ghost">
              {requests(length(result.exchanges))}
            </span>
            <p>{result.title}</p>
            <p :if={result.message}>{result.message}</p>
          </summary>
          <div class="collapse-content space-y-2">
            <p :if={result.evidence == :run}>
              This check judges every response in the run: the requests are in the other rows.
            </p>
            <p :if={result.exchanges == [] and result.evidence != :run}>
              This check made no HTTP requests.
            </p>
            <.exchange :for={exchange <- result.exchanges} row={dom_id} exchange={exchange} />
          </div>
        </details>
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

  attr :row, :string,
    required: true,
    doc: "the result row's DOM id; an exchange can show in several rows"

  attr :exchange, :map, required: true

  defp exchange(assigns) do
    ~H"""
    <details id={"#{@row}-exchange-#{@exchange.id}"} class="collapse collapse-arrow bg-base-100">
      <summary class="collapse-title">
        <span class={["badge", exchange_class(@exchange)]}>{@exchange.status || "ERR"}</span>
        <code>{@exchange.method} {@exchange.path}</code>
        <span :if={@exchange.kind == :hook} class="badge badge-ghost">hook</span>
        <span>{@exchange.duration_ms} ms</span>
      </summary>
      <div class="collapse-content">
        <.list>
          <:item title="URL"><code>{@exchange.url}</code></:item>
          <:item title="Request headers">
            <pre class="whitespace-pre-wrap">{@exchange.request_headers}</pre>
          </:item>
          <:item :if={@exchange.request_body} title="Request body">
            <pre class="whitespace-pre-wrap">{@exchange.request_body}</pre>
          </:item>
          <:item title="Response headers">
            <pre class="whitespace-pre-wrap">{@exchange.response_headers}</pre>
          </:item>
          <:item title={if @exchange.error, do: "Error", else: "Response body"}>
            <pre class="whitespace-pre-wrap">{@exchange.error || @exchange.response_body}</pre>
          </:item>
        </.list>
      </div>
    </details>
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
        [log_entry(exchange)],
        &[log_entry(exchange) | &1]
      )

    {:noreply,
     assign(socket,
       pending: pending,
       current: %{check_id: check_id, requests: length(pending[check_id])}
     )}
  end

  def handle_info({:run_event, {:result, result}}, socket) do
    {own, pending} = Map.pop(socket.assigns.pending, result.id, [])
    own = Enum.reverse(own)
    own_ids = MapSet.new(own, & &1.id)

    cited =
      for id <- result.exchanges,
          not MapSet.member?(own_ids, id),
          entry = socket.assigns.setup[id],
          do: entry

    {:noreply,
     socket
     |> insert_phases()
     |> assign(pending: pending, current: nil)
     |> update(:done, &(&1 + 1))
     |> update(:counts, &Map.update!(&1, result.status, fn count -> count + 1 end))
     |> stream_insert(:results, %{result | exchanges: cited ++ own})}
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
        |> stream_insert(:results, phase_row(phase, exchanges))
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

  defp requests(1), do: "1 request"
  defp requests(count), do: "#{count} requests"

  # An exchange as the log shows it: headers as lines, JSON bodies pretty-printed,
  # long bodies cut (the downloaded report holds more).
  defp log_entry(exchange) do
    uri = URI.parse(exchange.url)

    %{
      id: exchange.id,
      kind: exchange.kind,
      check_id: exchange.check_id,
      method: exchange.method,
      url: exchange.url,
      path: (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: ""),
      status: exchange.status,
      duration_ms: exchange.duration_ms,
      error: exchange.error,
      request_headers: header_lines(exchange.request_headers),
      request_body: display_body(exchange.request_body),
      response_headers: header_lines(exchange.response_headers),
      response_body: display_body(exchange.response_body)
    }
  end

  defp header_lines([]), do: "(none)"

  defp header_lines(headers),
    do: Enum.map_join(headers, "\n", fn [name, value] -> "#{name}: #{value}" end)

  defp display_body(nil), do: nil
  defp display_body(""), do: nil

  defp display_body(body) do
    pretty =
      case Jason.decode(body) do
        {:ok, _json} -> Jason.Formatter.pretty_print(body)
        {:error, _reason} -> body
      end

    if String.length(pretty) > @live_body_chars do
      String.slice(pretty, 0, @live_body_chars) <>
        "\n…[cut in the live log; the JSON report holds more]"
    else
      pretty
    end
  end

  defp exchange_class(%{status: status}) when status in 200..299, do: "badge-success"
  defp exchange_class(%{status: status}) when status in 300..499, do: "badge-info"
  defp exchange_class(_exchange), do: "badge-error"

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
