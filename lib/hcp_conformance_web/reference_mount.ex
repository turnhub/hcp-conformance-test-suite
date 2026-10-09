defmodule HcpConformanceWeb.ReferenceMount do
  @moduledoc """
  Serves the reference HCP implementation at `/reference`, so anyone can see a
  passing run and try the conformance hook without a target of their own.

  It sits in the endpoint before `Plug.Parsers`: the reference server reads raw
  request bodies (an HCP client's body is evidence, not form input). It holds only
  synthetic, in-memory subjects.
  """

  @behaviour Plug

  alias HcpConformance.Reference.Server
  alias HcpConformance.Settings

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["reference" | rest]} = conn, _opts) do
    if Settings.reference_server?() do
      opts =
        Server.init(
          store: HcpConformance.Reference.DefaultStore,
          hook_secret: Settings.reference_hook_secret(),
          base_url: base_url()
        )

      %{conn | path_info: rest, script_name: conn.script_name ++ ["reference"]}
      |> Server.call(opts)
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  @doc "The reference implementation's public base URL."
  @spec base_url() :: String.t()
  def base_url, do: HcpConformanceWeb.Endpoint.url() <> "/reference"
end
