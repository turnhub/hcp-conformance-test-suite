defmodule HcpConformanceWeb.SessionController do
  @moduledoc """
  Connecting to a target: the form takes the target's URL and credentials and
  keeps them in the session cookie, which the endpoint encrypts. The server
  stores nothing; disconnecting drops them from the cookie.
  """

  use HcpConformanceWeb, :controller

  alias HcpConformance.Runs
  alias HcpConformance.Settings
  alias HcpConformanceWeb.ReferenceMount

  @fields ~w(target discovery_url hook_url hook_secret person_token agent_token subject_did category)
  @secrets ~w(hook_secret person_token agent_token)

  @doc "The connection fields a session may hold."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  def new(conn, _params) do
    connection = get_session(conn, :connection)
    render_form(conn, Map.drop(connection || %{}, @secrets), connection)
  end

  def create(conn, %{"connection" => params}) do
    connection =
      params
      |> Map.take(@fields)
      |> Enum.reject(fn {_key, value} -> not is_binary(value) or String.trim(value) == "" end)
      |> Map.new(fn {key, value} -> {key, String.trim(value)} end)

    case Runs.config(connection) do
      {:ok, _config} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:connection, connection)
        |> redirect(to: ~p"/run")

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_flash(:error, message)
        |> render_form(Map.drop(connection, @secrets), nil)
    end
  end

  def create(conn, _params), do: create(conn, %{"connection" => %{}})

  def delete(conn, _params) do
    conn
    |> delete_session(:connection)
    |> put_flash(:info, "Disconnected. The credentials are gone from your session.")
    |> redirect(to: ~p"/")
  end

  defp render_form(conn, values, connection) do
    render(conn, :new,
      page_title: "Connect",
      form: Phoenix.Component.to_form(values, as: :connection),
      connection: connection,
      reference: reference()
    )
  end

  defp reference do
    if Settings.reference_server?() do
      base = ReferenceMount.base_url()

      %{
        target: base,
        hook_url: base <> "/conformance-hook",
        hook_secret: Settings.reference_hook_secret()
      }
    end
  end
end
