defmodule HcpConformance.V2.McpClientTest do
  # The suite's MCP client against a scripted endpoint: the request it sends, and
  # the two ways a server may answer one, a JSON object or an SSE stream.
  use ExUnit.Case, async: true

  import Plug.Conn

  alias HcpConformance.{Config, Context, HTTP.Response, V2.Mcp}

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%Plug.Conn{path_info: [".well-known", "hcp-configuration"]} = conn, _opts) do
      base = "http://127.0.0.1:#{conn.port}"

      document = %{
        "hcp_version" => "2.0",
        "bindings" => ["mcp"],
        "mcp_endpoint" => base <> "/mcp"
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(document))
    end

    def call(%Plug.Conn{path_info: ["mcp"]} = conn, opts) do
      {:ok, raw, conn} = read_body(conn)
      request = Jason.decode!(raw)
      send(opts[:test], {:mcp_request, Map.new(conn.req_headers), request})
      opts[:reply].(conn, request)
    end
  end

  defp context(reply) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Endpoint, test: self(), reply: reply},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, config} = Config.new(%{target: "http://127.0.0.1:#{port}", allow_private: true})
    Context.start(config)
  end

  defp json(conn, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))

  defp result(request, result),
    do: %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}

  test "a request carries its version and method in the body and, mirrored, in headers" do
    ctx =
      context(fn conn, request ->
        json(conn, result(request, %{"structuredContent" => %{"entries" => []}}))
      end)

    assert {:ok, %{"structuredContent" => %{"entries" => []}}} =
             Mcp.call(ctx, "grant-token-123456", "hcp_queryContext", %{"query" => "shoes"})

    assert_received {:mcp_request, headers, body}
    assert %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => params} = body
    assert %{"name" => "hcp_queryContext", "arguments" => %{"query" => "shoes"}} = params
    assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"

    assert headers["mcp-protocol-version"] == "2026-07-28"
    assert headers["mcp-method"] == "tools/call"
    assert headers["mcp-name"] == "hcp_queryContext"
    assert headers["authorization"] == "Bearer grant-token-123456"
    assert headers["accept"] =~ "application/json" and headers["accept"] =~ "text/event-stream"
  end

  test "a reply sent as an SSE stream is read past its notifications to the response" do
    ctx =
      context(fn conn, request ->
        progress = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"progress" => 1}
        }

        final = result(request, %{"structuredContent" => %{"entry" => %{"ref" => "r_1"}}})

        body =
          ": keep-alive\r\n\r\nevent: message\ndata: #{Jason.encode!(progress)}\n\ndata: #{Jason.encode!(final)}\n\n"

        conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
      end)

    assert Mcp.call!(ctx, "grant-token-123456", "hcp_getEntry", %{"ref" => "r_1"}) == %{
             "entry" => %{"ref" => "r_1"}
           }
  end

  test "the four kinds of reply are told apart" do
    ctx =
      context(fn conn, request ->
        case request["params"]["name"] do
          "tool_error" ->
            failure = %{
              "isError" => true,
              "structuredContent" => %{"type" => "scope-denied", "detail" => "no"}
            }

            json(conn, result(request, failure))

          "rpc_error" ->
            json(conn, %{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "error" => %{"code" => -32_602, "message" => "Unknown tool"}
            })

          "challenge" ->
            conn
            |> put_resp_header(
              "www-authenticate",
              ~s(Bearer error="insufficient_scope", scope="hcp:a:read hcp:b:read", error_description="needs more")
            )
            |> send_resp(403, "")
        end
      end)

    reply = Mcp.call(ctx, "grant-token-123456", "tool_error", %{})
    assert {:tool_error, _result} = reply
    assert %{"type" => "scope-denied"} = Mcp.tool_error!(reply, "scope-denied", "a denial")

    assert {:rpc_error, %{"code" => -32_602}} =
             Mcp.call(ctx, "grant-token-123456", "rpc_error", %{})

    assert {:http, %Response{status: 403} = response} =
             Mcp.call(ctx, "grant-token-123456", "challenge", %{})

    assert Mcp.challenge(response) == %{
             "error" => "insufficient_scope",
             "scope" => "hcp:a:read hcp:b:read",
             "error_description" => "needs more"
           }
  end
end
