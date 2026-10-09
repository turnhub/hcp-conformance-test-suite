defmodule HcpConformance.Web.Endpoint do
  @moduledoc """
  The top-level plug. `/reference/*` goes straight to the reference HCP server
  (which must see the raw request body, so it bypasses the router's parsers);
  everything else is the runner.
  """

  @behaviour Plug

  alias HcpConformance.Reference.Server
  alias HcpConformance.Web.Router

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["reference" | rest]} = conn, _opts) do
    if Application.get_env(:hcp_conformance, :reference_server, true) do
      conn = %{conn | path_info: rest, script_name: conn.script_name ++ ["reference"]}

      base_url =
        case Application.get_env(:hcp_conformance, :public_url) do
          url when is_binary(url) and url != "" -> String.trim_trailing(url, "/") <> "/reference"
          _unset -> nil
        end

      opts =
        Server.init(
          store: HcpConformance.Reference.DefaultStore,
          hook_secret: Application.get_env(:hcp_conformance, :reference_hook_secret, "reference-hook-secret"),
          base_url: base_url
        )

      Server.call(conn, opts)
    else
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  def call(conn, _opts), do: Router.call(conn, Router.init([]))
end
