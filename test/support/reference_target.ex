defmodule HcpConformance.ReferenceTarget do
  @moduledoc """
  Starts a reference HCP server on a random local port, optionally with faults
  switched on. `version: "2.0"` starts the v2 reference instead of the v1 one.
  """

  # Test support only: it serves the reference for the suite's tests to run against.
  use Boundary, top_level?: true, deps: [HcpConformance.Reference]

  alias HcpConformance.Reference.{Server, ServerV2, Store}

  @secret "test-hook-secret"

  @spec start!(keyword()) :: map()
  def start!(opts \\ []) do
    {:ok, store} = Store.start_link()
    server = if opts[:version] == "2.0", do: ServerV2, else: Server
    plug = {server, store: store, hook_secret: @secret, faults: Keyword.get(opts, :faults, [])}
    {:ok, pid} = Bandit.start_link(plug: plug, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    base = "http://127.0.0.1:#{port}"

    %{
      base: base,
      hook_url: base <> "/conformance-hook",
      hook_secret: @secret,
      server: pid,
      store: store
    }
  end

  @doc "Run attributes for the hook mode against a started target."
  @spec hook_config(map(), map()) :: map()
  def hook_config(target, extra \\ %{}) do
    Map.merge(
      %{
        target: target.base,
        hook_url: target.hook_url,
        hook_secret: target.hook_secret,
        allow_private: true
      },
      extra
    )
  end

  @doc "Creates a subject through the hook and returns its person token."
  @spec person_token!(map()) :: String.t()
  def person_token!(target), do: subject!(target).person_token

  @doc "Creates a subject through the hook and returns its person token and identifier."
  @spec subject!(map()) :: %{person_token: String.t(), subject_did: String.t()}
  def subject!(target) do
    %{status: 201, body: %{"personToken" => token, "subjectDid" => did}} =
      Req.post!(target.hook_url <> "/subjects",
        json: %{},
        auth: {:bearer, target.hook_secret},
        retry: false
      )

    %{person_token: token, subject_did: did}
  end

  @doc "A readable list of the results that did not pass, for assertion messages."
  @spec failures(map(), [atom()]) :: String.t()
  def failures(report, statuses \\ [:fail, :error, :warn]) do
    report.results
    |> Enum.filter(&(&1.status in statuses))
    |> Enum.map_join("\n", &"#{&1.status} #{&1.id}: #{&1.message}")
  end
end
