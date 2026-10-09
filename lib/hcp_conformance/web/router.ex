defmodule HcpConformance.Web.Router do
  @moduledoc """
  The hosted runner: an HTML form and report pages, and a JSON API for CI.

      POST /api/runs        {"target": …, "hook_url": …, "hook_secret": …}  -> 202 {"id", "status_url", "report_url"}
      GET  /api/runs/:id    status, and the report once finished
      GET  /api/checks      the catalogue
  """

  use Plug.Router

  alias HcpConformance.Catalog
  alias HcpConformance.Web.{Html, Runs, RunStore}

  @hook_doc File.read!(Path.expand("../../../docs/HOOK.md", __DIR__))
  @external_resource Path.expand("../../../docs/HOOK.md", __DIR__)

  plug(:basic_auth)
  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason, pass: ["*/*"], length: 1_000_000)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/" do
    html(conn, 200, Html.home(%{reference: reference(conn), error: nil}))
  end

  get "/checks" do
    html(conn, 200, Html.checks())
  end

  get "/docs/hook" do
    html(conn, 200, Html.document("Conformance hook", @hook_doc))
  end

  post "/runs" do
    params = form_params(conn.body_params)

    case Runs.start(params) do
      {:ok, id} ->
        conn |> put_resp_header("location", "/runs/" <> id) |> send_resp(303, "")

      {:error, :busy} ->
        html(
          conn,
          429,
          Html.home(%{
            reference: reference(conn),
            error: "The suite is busy with other runs. Try again in a minute."
          })
        )

      {:error, message} ->
        html(conn, 422, Html.home(%{reference: reference(conn), error: message}))
    end
  end

  get "/runs/:id" do
    case RunStore.get(id) do
      nil -> html(conn, 404, Html.error("No such run. Runs are kept in memory and expire."))
      run -> html(conn, 200, Html.run(run))
    end
  end

  post "/api/runs" do
    case Runs.start(form_params(conn.body_params)) do
      {:ok, id} ->
        json(conn, 202, %{id: id, status_url: "/api/runs/" <> id, report_url: "/runs/" <> id})

      {:error, :busy} ->
        conn |> put_resp_header("retry-after", "60") |> json(429, %{error: "busy"})

      {:error, message} ->
        json(conn, 422, %{error: message})
    end
  end

  get "/api/runs/:id/report.json" do
    case RunStore.get(id) do
      %{report: %{} = report} ->
        conn
        |> put_resp_header("content-disposition", ~s(attachment; filename="hcp-conformance-#{id}.json"))
        |> json(200, report)

      %{} ->
        json(conn, 409, %{error: "the run has not finished"})

      nil ->
        json(conn, 404, %{error: "no such run"})
    end
  end

  get "/api/runs/:id" do
    case RunStore.get(id) do
      nil ->
        json(conn, 404, %{error: "no such run"})

      run ->
        json(
          conn,
          200,
          Map.take(run, [:id, :status, :config, :created_at, :total, :results, :setup_notes, :error, :report])
        )
    end
  end

  get "/api/checks" do
    checks =
      Enum.map(Catalog.all(), &Map.take(&1, [:id, :section, :level, :title, :group, :requires, :phase]))

    json(conn, 200, %{checks: checks})
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # The form posts groups[] as a list; the API may send any Config attribute.
  defp form_params(params) do
    params
    |> Map.take(
      ~w(target discovery_url hook_url hook_secret person_token agent_token subject_did category groups only label)
    )
    |> Map.update("groups", nil, fn groups ->
      # Every group ticked is the same as no filter.
      if is_list(groups) and Enum.sort(groups) == Enum.sort(Catalog.groups()), do: nil, else: groups
    end)
  end

  defp reference(conn) do
    if Application.get_env(:hcp_conformance, :reference_server, true) do
      base = public_url(conn) <> "/reference"

      %{
        target: base,
        hook_url: base <> "/conformance-hook",
        hook_secret: Application.get_env(:hcp_conformance, :reference_hook_secret, "reference-hook-secret")
      }
    end
  end

  @doc false
  def public_url(conn) do
    case Application.get_env(:hcp_conformance, :public_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _unset ->
        scheme = get_req_header(conn, "x-forwarded-proto") |> List.first() || to_string(conn.scheme)
        port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
        "#{scheme}://#{conn.host}#{port}"
    end
  end

  defp basic_auth(%{path_info: ["health"]} = conn, _opts), do: conn

  defp basic_auth(conn, _opts) do
    case Application.get_env(:hcp_conformance, :basic_auth) do
      credentials when is_binary(credentials) and credentials != "" ->
        [username, password] = String.split(credentials, ":", parts: 2)
        Plug.BasicAuth.basic_auth(conn, username: username, password: password)

      _unset ->
        conn
    end
  end

  defp html(conn, status, body) do
    conn |> put_resp_content_type("text/html") |> send_resp(status, body)
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
