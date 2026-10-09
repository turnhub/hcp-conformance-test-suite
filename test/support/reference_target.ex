defmodule HcpConformance.ReferenceTarget do
  @moduledoc "Starts a reference HCP server on a random local port, optionally with faults switched on."

  # Test support only: it serves the reference for the suite's tests to run against.
  use Boundary, top_level?: true, deps: [HcpConformance.Reference]

  alias HcpConformance.Reference.{Server, Store}

  @secret "test-hook-secret"

  @spec start!(keyword()) :: map()
  def start!(opts \\ []) do
    {:ok, store} = Store.start_link()
    plug = {Server, store: store, hook_secret: @secret, faults: Keyword.get(opts, :faults, [])}
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
  def person_token!(target) do
    %{status: 201, body: %{"personToken" => token}} =
      Req.post!(target.hook_url <> "/subjects",
        json: %{},
        auth: {:bearer, target.hook_secret},
        retry: false
      )

    token
  end

  @doc "A readable list of the results that did not pass, for assertion messages."
  @spec failures(map(), [atom()]) :: String.t()
  def failures(report, statuses \\ [:fail, :error, :warn]) do
    report.results
    |> Enum.filter(&(&1.status in statuses))
    |> Enum.map_join("\n", &"#{&1.status} #{&1.id}: #{&1.message}")
  end
end
