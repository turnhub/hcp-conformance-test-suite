defmodule HcpConformanceWeb.ReferenceMount do
  @moduledoc """
  Serves the reference HCP implementations, so anyone can see a passing run and
  try the conformance hook without a target of their own: v1 at `/reference`, and
  v2 inside it at `/reference/hcp-v2`, which keeps both within the one loopback
  mount the private-network guard lets runs reach.

  It sits in the endpoint before `Plug.Parsers`: the reference server reads raw
  request bodies (an HCP client's body is evidence, not form input). It holds only
  synthetic, in-memory subjects.
  """

  @behaviour Plug

  alias HcpConformance.Reference.{Server, ServerV2}
  alias HcpConformance.Settings

  @v2 "hcp-v2"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["reference", @v2 | rest]} = conn, _opts),
    do: serve(conn, ServerV2, HcpConformance.Reference.DefaultStoreV2, ["reference", @v2], rest)

  def call(%Plug.Conn{path_info: ["reference" | rest]} = conn, _opts),
    do: serve(conn, Server, HcpConformance.Reference.DefaultStore, ["reference"], rest)

  def call(conn, _opts), do: conn

  @spec serve(Plug.Conn.t(), module(), atom(), [String.t()], [String.t()]) :: Plug.Conn.t()
  defp serve(conn, server, store, mount, rest) do
    if Settings.reference_server?() do
      opts =
        server.init(
          store: store,
          hook_secret: Settings.reference_hook_secret(),
          base_url: base_url(conn) <> suffix(mount)
        )

      %{conn | path_info: rest, script_name: conn.script_name ++ mount}
      |> server.call(opts)
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp suffix(["reference", version]), do: "/" <> version
  defp suffix(_v1), do: ""

  @doc "The reference implementation's public base URL."
  @spec base_url() :: String.t()
  def base_url, do: HcpConformanceWeb.Endpoint.url() <> "/reference"

  @doc """
  Where this instance reaches the reference implementation itself: on loopback,
  on its own port, so nothing in front of the public URL gets in the way.
  """
  @spec local_url() :: String.t()
  def local_url do
    case Settings.local_reference_url() do
      url when is_binary(url) -> url
      nil -> base_url()
    end
  end

  @doc "Where this instance reaches the reference implementation of a specification version."
  @spec local_url(String.t()) :: String.t()
  def local_url("2.0"), do: local_url() <> "/" <> @v2
  def local_url(_v1), do: local_url()

  # A request on loopback came from this instance, so its discovery document
  # points back at loopback; anyone else gets the public URL.
  @spec base_url(Plug.Conn.t()) :: String.t()
  defp base_url(%Plug.Conn{host: "127.0.0.1"}), do: local_url()
  defp base_url(_conn), do: base_url()
end
