defmodule HcpConformanceWeb.ApiController do
  @moduledoc """
  The JSON API, for pipelines. A run is synchronous: the response is the report,
  and nothing is kept once it is sent.

      POST /api/runs   {"target": …, "hook_url": …, "hook_secret": …}  -> 200 report
      GET  /api/checks                                                   -> the catalogue

  `spec_version` (`"1.0"` or `"2.0"`) picks the specification: in a run's body,
  where leaving it out reads the version from the target's discovery document,
  and as a query parameter of the catalogue, which defaults to v1.
  """

  use HcpConformanceWeb, :controller

  alias HcpConformance.{Catalog, Runs, Spec}
  alias HcpConformanceWeb.SessionController

  def create(conn, params) do
    attrs = Map.take(params, SessionController.fields() ++ ~w(groups only))

    with {:ok, config} <- Runs.config(attrs),
         {:ok, report} <- Runs.run(config) do
      json(conn, report)
    else
      {:error, :busy} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(:too_many_requests)
        |> json(%{error: "busy: too many runs in progress"})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  def checks(conn, params) do
    case Spec.parse(params["spec_version"]) do
      {:ok, version} ->
        version = version || Spec.default()

        checks =
          Enum.map(
            Catalog.all(version),
            &Map.take(&1, [:id, :section, :level, :title, :group, :requires, :phase])
          )

        json(conn, %{spec_version: Spec.draft(version), checks: checks})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "unknown spec_version"})
    end
  end

  def health(conn, _params), do: text(conn, "ok")
end
