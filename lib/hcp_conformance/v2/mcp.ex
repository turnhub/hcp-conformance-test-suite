defmodule HcpConformance.V2.Mcp do
  @moduledoc """
  The suite's MCP client, for the MCP Binding over Streamable HTTP (HCP v2 §10,
  MCP revision 2026-07-28). That revision is stateless: every request is its own
  POST, carrying the protocol version in its `_meta` and mirrored in headers,
  and the bearer token of the grant it acts under. There is no handshake and no
  session to keep.

  A reply is one of four things, and the checks tell them apart (§10.4):

  - a tool result (`{:ok, structured}`),
  - a tool execution error carrying a Core error (`{:tool_error, error}`), which
    reaches the model,
  - a JSON-RPC protocol error (`{:rpc_error, error}`),
  - a refusal at the HTTP layer (`{:http, response}`): 401, or a 403 challenge,
    which reaches the host that holds the grant.
  """

  alias HcpConformance.{Assert, Context, HTTP.Response}

  @protocol "2026-07-28"
  @meta "io.modelcontextprotocol/"
  @extension "example.hcp/hcp"

  @type reply ::
          {:ok, map()}
          | {:tool_error, map()}
          | {:rpc_error, map()}
          | {:http, Response.t()}

  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The identifier of the extension an HCP server announces itself under (§10.2)."
  @spec extension() :: String.t()
  def extension, do: @extension

  @doc "The MCP endpoint the discovery document publishes, or a failure saying it is missing."
  @spec endpoint!(Context.t()) :: String.t()
  def endpoint!(%Context{endpoints: %{mcp: url}}) when is_binary(url), do: url

  def endpoint!(_ctx),
    do: Assert.fail!("the MCP Binding is listed, but the discovery document has no mcp_endpoint")

  @doc """
  Sends one JSON-RPC request and returns the HTTP response with the JSON-RPC
  message it carried, if any: the body itself, or the response event of an SSE
  stream. `token: nil` sends no authorization.
  """
  @spec request(Context.t(), String.t() | nil, String.t(), map()) :: {Response.t(), map() | nil}
  def request(ctx, token, method, params \\ %{}) do
    params =
      Map.put(params, "_meta", %{
        (@meta <> "protocolVersion") => @protocol,
        (@meta <> "clientInfo") => %{"name" => "hcp-conformance-suite", "version" => "1"},
        (@meta <> "clientCapabilities") => %{}
      })

    id = "hcpc-" <> Context.random_word(8)
    body = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    headers =
      [
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @protocol},
        {"mcp-method", method}
      ] ++ if(is_binary(params["name"]), do: [{"mcp-name", params["name"]}], else: [])

    response =
      Context.request(ctx, :post, endpoint!(ctx), token: token, json: body, headers: headers)

    {response, message(response, id)}
  end

  # A server answers with a single JSON object or with an SSE stream scoped to
  # the request, whose events may be notifications before the response.
  defp message(%Response{json: %{"jsonrpc" => _} = message}, _id), do: message

  defp message(%Response{content_type: "text/event-stream", body: body}, id)
       when is_binary(body) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.map(&event_data/1)
    |> Enum.find(&(is_map(&1) and &1["id"] == id))
  end

  defp message(_response, _id), do: nil

  defp event_data(event) do
    data =
      for "data:" <> line <- String.split(event, ~r/\r?\n/),
          into: "",
          do: String.trim_leading(line)

    case Jason.decode(data) do
      {:ok, message} -> message
      {:error, _reason} -> nil
    end
  end

  @doc "Calls a tool with the grant's token and says which kind of reply came back."
  @spec call(Context.t(), String.t() | nil, String.t(), map()) :: reply()
  def call(ctx, token, tool, arguments) do
    case request(ctx, token, "tools/call", %{"name" => tool, "arguments" => arguments}) do
      {%Response{status: status}, %{"result" => %{"isError" => true} = result}}
      when status in 200..299 ->
        {:tool_error, result}

      {%Response{status: status}, %{"result" => %{} = result}} when status in 200..299 ->
        {:ok, result}

      {_response, %{"error" => %{} = error}} ->
        {:rpc_error, error}

      {response, _none} ->
        {:http, response}
    end
  end

  @doc "Calls a tool and returns its `structuredContent`; any other reply fails the check."
  @spec call!(Context.t(), String.t(), String.t(), map()) :: map()
  def call!(ctx, token, tool, arguments) do
    case call(ctx, token, tool, arguments) do
      {:ok, %{"structuredContent" => %{} = structured}} ->
        structured

      {:ok, _result} ->
        Assert.fail!("#{tool}: the result carries no structuredContent object")

      other ->
        Assert.fail!("#{tool}: expected a tool result, got #{describe(other)}")
    end
  end

  @doc "The Core error of a tool execution error: its `type` code, or a failure saying what came instead."
  @spec tool_error!(reply(), String.t(), String.t()) :: map()
  def tool_error!({:tool_error, %{"structuredContent" => %{"type" => type} = error}}, code, what) do
    Assert.check!(type == code, "#{what}: expected the tool error #{code}, got #{inspect(type)}")
    Assert.check!(is_binary(error["detail"]), "#{what}: a tool error carries a detail")
    error
  end

  def tool_error!(reply, code, what),
    do:
      Assert.fail!(
        "#{what}: expected a tool execution error carrying #{code}, got #{describe(reply)}"
      )

  @doc "A short description of a reply, for failure messages."
  @spec describe(reply()) :: String.t()
  def describe({:ok, _result}), do: "a tool result"

  def describe({:tool_error, result}),
    do: "a tool execution error (#{inspect(get_in(result, ["structuredContent", "type"]))})"

  def describe({:rpc_error, error}),
    do: "a JSON-RPC error #{inspect(error["code"])} (#{error["message"]})"

  def describe({:http, response}), do: "HTTP #{response.status}#{Assert.body_hint(response)}"

  @doc "The parameters of a Bearer challenge in a response's `WWW-Authenticate` header (RFC 6750)."
  @spec challenge(Response.t()) :: %{optional(String.t()) => String.t()}
  def challenge(%Response{headers: headers}) do
    case Enum.find(headers, fn {name, _value} -> String.downcase(name) == "www-authenticate" end) do
      {_name, "Bearer" <> params} ->
        ~r/([a-z_]+)="([^"]*)"/
        |> Regex.scan(params, capture: :all_but_first)
        |> Map.new(fn [key, value] -> {key, value} end)

      _absent ->
        %{}
    end
  end
end
