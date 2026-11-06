defmodule HcpConformance.HTTPTest do
  use ExUnit.Case, async: true

  alias HcpConformance.HTTP
  alias HcpConformance.Transcript

  # Echoes what the server saw of the request: the suite's claims about the
  # connection (which address, which Host header) are checked against this.
  defmodule Echo do
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          host: Plug.Conn.get_req_header(conn, "host"),
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string,
          authorization: Plug.Conn.get_req_header(conn, "authorization"),
          body: body
        })
      )
    end
  end

  setup do
    {:ok, server} = Bandit.start_link(plug: Echo, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, transcript} = Transcript.start_link()
    %{port: port, transcript: transcript}
  end

  test "connects to the address the guard vetted, resolving the name only once", ctx do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    # A rebinding resolver: the first answer passes the guard, every later one
    # would send the connection elsewhere (here: nowhere at all).
    resolver = fn "pinned.test" ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:ok, [{127, 0, 0, 1}]}
        _later -> {:error, :nxdomain}
      end
    end

    response =
      HTTP.request(ctx.transcript, true, :post, "http://pinned.test:#{ctx.port}/v1/search",
        token: "secret-token",
        json: %{"query" => "arch"},
        params: [limit: 2],
        resolver: resolver
      )

    assert response.status == 200
    assert Agent.get(calls, & &1) == 1

    assert response.json["host"] == ["pinned.test:#{ctx.port}"]
    assert response.json["method"] == "POST"
    assert response.json["path"] == "/v1/search"
    assert response.json["query"] == "limit=2"
    assert response.json["authorization"] == ["Bearer secret-token"]
    assert Jason.decode!(response.json["body"]) == %{"query" => "arch"}

    # The transcript keeps the URL as submitted, never the address behind it.
    assert [%{url: "http://pinned.test:" <> _rest, status: 200}] =
             Transcript.exchanges(ctx.transcript)
  end

  test "a refused target is recorded and raised, without a connection", ctx do
    resolver = fn _host -> {:ok, [{10, 0, 0, 5}]} end

    assert_raise HTTP.TransportError, ~r/non-public/, fn ->
      HTTP.request(ctx.transcript, false, :get, "http://corp.test:#{ctx.port}/",
        resolver: resolver
      )
    end

    assert [%{status: nil, error: error}] = Transcript.exchanges(ctx.transcript)
    assert error =~ "non-public"
    refute error =~ "10.0.0.5"
  end

  test "a target that does not answer in time is a transport error, not a hang", ctx do
    # Nothing listens on this port: refused at once.
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, free_port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert_raise HTTP.TransportError, fn ->
      HTTP.request(ctx.transcript, true, :get, "http://127.0.0.1:#{free_port}/", timeout: 500)
    end

    _ = ctx
  end
end
