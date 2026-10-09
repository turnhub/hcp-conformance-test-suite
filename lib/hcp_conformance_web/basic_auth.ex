defmodule HcpConformanceWeb.BasicAuth do
  @moduledoc """
  Puts the runner behind basic auth when the deployment sets `UI_BASIC_AUTH`
  (`user:password`). Visitors hand the runner credentials for their own systems,
  so an instance whose operator they cannot vouch for should be closed.
  """

  @behaviour Plug

  alias HcpConformance.Settings

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Settings.basic_auth() do
      nil ->
        conn

      credentials ->
        [username, password] = String.split(credentials, ":", parts: 2)
        Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    end
  end
end
