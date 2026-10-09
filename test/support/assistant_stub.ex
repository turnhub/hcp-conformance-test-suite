defmodule HcpConformance.AssistantStub do
  @moduledoc """
  A stand-in for OpenAI's Responses API or Anthropic's Messages API on a random
  local port. It answers every request with one canned response and sends what
  it received to the test.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Starts the stub; returns the base URL to use in place of the provider's `/v1`.
  `response` is one `{status, body}` for every request, or a function of the
  decoded request body returning one.
  """
  @spec start!(pid(), {pos_integer(), map()} | (map() -> {pos_integer(), map()})) :: String.t()
  def start!(test, response) do
    plug = {__MODULE__, test: test, response: response}
    {:ok, pid} = Bandit.start_link(plug: plug, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}/v1"
  end

  @doc "An OpenAI response whose output is `text`, after a reasoning item, as OpenAI sends it."
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

  @doc "An Anthropic message whose text is `text`, after an empty thinking block, as Claude sends it."
  @spec claude_reply(String.t()) :: {200, map()}
  def claude_reply(text) do
    {200,
     %{
       "id" => "msg_stub",
       "type" => "message",
       "role" => "assistant",
       "model" => "claude-opus-5-5",
       "stop_reason" => "end_turn",
       "stop_details" => nil,
       "content" => [
         %{"type" => "thinking", "thinking" => "", "signature" => "sig"},
         %{"type" => "text", "text" => text}
       ]
     }}
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)

    send(opts[:test], {
      :assistant_request,
      %{
        path: conn.request_path,
        authorization: get_req_header(conn, "authorization"),
        headers: Map.new(conn.req_headers),
        body: Jason.decode!(body)
      }
    })

    {status, json} =
      case opts[:response] do
        respond when is_function(respond, 1) -> respond.(Jason.decode!(body))
        response -> response
      end

    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(json))
  end
end
