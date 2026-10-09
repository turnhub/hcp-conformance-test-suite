defmodule HcpConformance.OpenAIStub do
  @moduledoc """
  A stand-in for OpenAI's Responses API on a random local port. It answers every
  request with one canned response and sends what it received to the test.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts the stub; returns the base URL to use in place of https://api.openai.com/v1."
  @spec start!(pid(), {pos_integer(), map()}) :: String.t()
  def start!(test, response) do
    plug = {__MODULE__, test: test, response: response}
    {:ok, pid} = Bandit.start_link(plug: plug, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}/v1"
  end

  @doc "A completed response whose output is `text`, after a reasoning item, as OpenAI sends it."
  @spec reply(String.t()) :: {200, map()}
  def reply(text) do
    {200,
     %{
       "id" => "resp_stub",
       "object" => "response",
       "status" => "completed",
       "output" => [
         %{"type" => "reasoning", "id" => "rs_stub", "summary" => []},
         %{
           "type" => "message",
           "role" => "assistant",
           "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
         }
       ]
     }}
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)

    send(opts[:test], {
      :openai_request,
      %{
        path: conn.request_path,
        authorization: get_req_header(conn, "authorization"),
        body: Jason.decode!(body)
      }
    })

    {status, json} = opts[:response]
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(json))
  end
end
