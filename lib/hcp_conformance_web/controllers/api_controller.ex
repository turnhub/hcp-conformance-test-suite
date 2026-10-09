defmodule HcpConformanceWeb.ApiController do
  @moduledoc """
  The JSON API, for pipelines. A run is synchronous: the response is the report,
  and nothing is kept once it is sent.

      POST /api/runs   {"target": …, "hook_url": …, "hook_secret": …}  -> 200 report
      GET  /api/checks                                                   -> the catalogue
  """

  use HcpConformanceWeb, :controller

  alias HcpConformance.{Catalog, Runs}
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

  def checks(conn, _params) do
    checks =
      Enum.map(
        Catalog.all(),
        &Map.take(&1, [:id, :section, :level, :title, :group, :requires, :phase])
      )

    json(conn, %{checks: checks})
  end

  def health(conn, _params), do: text(conn, "ok")
end
