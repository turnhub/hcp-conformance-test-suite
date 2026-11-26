defmodule HcpConformance.Reference.McpV2 do
  @moduledoc """
  The MCP Binding of the v2 reference implementation (HCP v2 §10), over
  Streamable HTTP as MCP revision 2026-07-28 defines it: stateless, one JSON-RPC
  request per POST, the protocol version in every request.

  This module holds what is MCP's own: reading and validating a request, the
  `server/discover` and `tools/list` results, turning a tool call into the Core
  operation it names, and turning that operation's outcome back into a tool
  result. `HcpConformance.Reference.ServerV2` authenticates the caller and runs
  the operation with the same code that serves the HTTP Binding, so a grant is
  enforced once, whichever binding carries the request.
  """

  @protocol "2026-07-28"
  @extension "example.hcp/hcp"
  @general_context "https://hcp.example/spec/profiles/general-context/2.0"
  @entry_schema "https://hcp.example/spec/entry/2.0"
  @schemas "https://hcp.example/schemas/2.0-draft-3/"
  @meta "io.modelcontextprotocol/"

  @purpose %{
    "type" => "string",
    "format" => "uri",
    "description" => "Purpose code: one of the purposes the person approved in the grant."
  }
  @purpose_description %{
    "type" => "string",
    "description" => "Optional. Plain language statement of the task. Logged to audit trail."
  }
  @declaration %{"type" => "string", "enum" => ["person-declared", "model-inferred"]}
  @confidence %{"type" => ["string", "null"], "enum" => ["high", "medium", "low", nil]}

  # name, description, properties, required, the Core result schema it returns.
  @tools [
    {"hcp_queryContext",
     "Retrieve minimal, relevant entries from the person's HCP instance for a stated purpose.",
     %{
       "query" => %{"type" => "string"},
       "categories" => %{"type" => "array", "items" => %{"type" => "string"}},
       "purpose" => @purpose,
       "purposeDescription" => @purpose_description,
       "maxEntries" => %{"type" => "integer", "default" => 5}
     }, ["query", "purpose"], "operations/query-result.json"},
    {"hcp_getEntry",
     "Retrieve one entry from the person's HCP instance by its ref, for a stated purpose.",
     %{
       "ref" => %{"type" => "string"},
       "purpose" => @purpose,
       "purposeDescription" => @purpose_description,
       "version" => %{"type" => "integer"}
     }, ["ref", "purpose"], "operations/get-entry-result.json"},
    {"hcp_createEntry", "Add a new entry to the person's HCP instance.",
     %{
       "categories" => %{
         "type" => "array",
         "items" => %{"type" => "string"},
         "minItems" => 1,
         "uniqueItems" => true
       },
       "dimension" => %{"type" => ["string", "null"]},
       "content" => %{"type" => "string"},
       "declarationType" => @declaration,
       "confidence" => @confidence,
       "assertedBy" => %{"type" => "string"},
       "sourceContext" => %{"type" => "string"},
       "basis" => %{"type" => "object"},
       "permittedPurposes" => %{
         "type" => "array",
         "items" => %{"type" => "string", "format" => "uri"}
       }
     }, ["categories", "content", "declarationType", "sourceContext"],
     "operations/create-result.json"},
    {"hcp_reviseEntry",
     "Revise an existing entry, creating a new version and preserving version history.",
     %{
       "ref" => %{"type" => "string"},
       "expectedVersion" => %{"type" => "integer"},
       "content" => %{"type" => "string"},
       "reason" => %{"type" => "string"},
       "declarationType" => @declaration,
       "confidence" => @confidence,
       "assertedBy" => %{"type" => "string"},
       "sourceContext" => %{"type" => "string"}
     }, ["ref", "expectedVersion", "content", "reason"], "operations/revise-result.json"},
    {"hcp_withdrawEntry",
     "Withdraw an entry. Withdrawn entries are hidden from agents immediately.",
     %{"ref" => %{"type" => "string"}, "reason" => %{"type" => "string"}}, ["ref", "reason"],
     "operations/withdraw-result.json"},
    {"hcp_reportSharing",
     "Report that you told another organization something from the person's context, as their grant allows.",
     %{
       "recipient" => %{
         "type" => "object",
         "properties" => %{"domain" => %{"type" => "string"}, "name" => %{"type" => "string"}},
         "required" => ["domain", "name"]
       },
       "refs" => %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 1},
       "purpose" => %{"type" => "string"},
       "sharedAt" => %{"type" => "string", "format" => "date-time"}
     }, ["recipient", "refs", "purpose", "sharedAt"], nil}
  ]

  @type response :: {pos_integer(), map() | nil, String.t() | nil, [{String.t(), String.t()}]}
  @type rpc :: %{id: term(), method: String.t(), params: map()}
  @type operation :: %{method: String.t(), path: [String.t()], query: map(), json: map() | nil}

  # Requests (MCP: Streamable HTTP, request metadata) -----------------------------------

  @doc """
  Reads the JSON-RPC request of a POST to the MCP endpoint. The protocol version
  and the method travel in the body and are mirrored in headers; a mismatch, or
  a version this server does not speak, is refused as MCP requires.
  """
  @spec parse(map()) :: {:ok, rpc()} | {:error, response()}
  def parse(%{json: %{"jsonrpc" => "2.0", "method" => method} = body, headers: headers})
      when is_binary(method) do
    rpc = %{id: body["id"], method: method, params: params(body)}
    version = get_in(rpc.params, ["_meta", @meta <> "protocolVersion"])

    cond do
      headers["mcp-protocol-version"] != version or headers["mcp-method"] != method or
          (method == "tools/call" and headers["mcp-name"] != rpc.params["name"]) ->
        {:error, error(rpc, 400, -32_020, "The request headers do not match the request body")}

      version != @protocol ->
        data = %{"supported" => [@protocol], "requested" => version}
        {:error, error(rpc, 400, -32_022, "Unsupported protocol version", data)}

      method not in ["server/discover", "tools/list", "tools/call"] ->
        {:error, error(rpc, 404, -32_601, "Method not found")}

      true ->
        {:ok, rpc}
    end
  end

  def parse(_request),
    do: {:error, error(%{id: nil}, 400, -32_600, "The body is not a JSON-RPC request")}

  defp params(%{"params" => %{} = params}), do: params
  defp params(_body), do: %{}

  # Results ---------------------------------------------------------------------------

  @doc "A JSON-RPC result, complete as every result of this server is."
  @spec result(rpc(), map()) :: response()
  def result(rpc, result) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => rpc.id,
      "result" => Map.put(result, "resultType", "complete")
    }

    {200, body, "application/json", []}
  end

  @doc "A JSON-RPC protocol error."
  @spec error(map(), pos_integer(), integer(), String.t(), map() | nil) :: response()
  def error(rpc, status, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error

    {status, %{"jsonrpc" => "2.0", "id" => rpc.id, "error" => error}, "application/json", []}
  end

  @doc """
  The `server/discover` result: MCP's capabilities, with the HCP extension that
  points at the discovery document and repeats its claims (§10.2).
  """
  @spec discover(String.t(), [String.t()]) :: map()
  def discover(base, conforms_to) do
    %{
      "supportedVersions" => [@protocol],
      "capabilities" => %{
        "tools" => %{},
        "extensions" => %{
          @extension => %{
            "discovery" => base <> "/.well-known/hcp-configuration",
            "conformsTo" => conforms_to
          }
        }
      },
      "_meta" => %{
        (@meta <> "serverInfo") => %{"name" => "HCP reference implementation", "version" => "2.0"}
      }
    }
  end

  @doc """
  The tools (§10.3): the context operations and nothing of the governance plane.
  `faults` may drop one or add a governance tool, for the suite's fault tests.
  """
  @spec tools(MapSet.t()) :: [map()]
  def tools(faults) do
    tools = Enum.map(@tools, &definition/1)

    tools =
      if MapSet.member?(faults, :mcp_missing_tool),
        do: Enum.reject(tools, &(&1["name"] == "hcp_getEntry")),
        else: tools

    if MapSet.member?(faults, :mcp_governance_tool),
      do: tools ++ [definition({"hcp_exportContext", "Export the vault.", %{}, [], nil})],
      else: tools
  end

  defp definition({name, description, properties, required, result}) do
    failure = %{"$ref" => @schemas <> "error.json"}

    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "properties" => properties,
        "required" => required
      },
      # Each tool's output is its Core result, or a Core error (§10.4).
      "outputSchema" =>
        if(result, do: %{"anyOf" => [%{"$ref" => @schemas <> result}, failure]}, else: failure)
    }
  end

  # Tool calls → Core operations (§10.3) ---------------------------------------------------

  @doc """
  The Core operation a tool call names, as the request the HTTP Binding would
  carry for it. `:unknown` for a tool this server does not have, which is a
  protocol error; `{:invalid, detail}` for arguments that miss a required one,
  which is the Core error invalid request.
  """
  @spec operation(map(), String.t()) :: {:ok, operation()} | {:invalid, String.t()} | :unknown
  def operation(%{"name" => name} = params, subject) do
    arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

    case List.keyfind(@tools, name, 0) do
      nil ->
        :unknown

      {^name, _description, _properties, required, _result} ->
        case Enum.reject(required, &Map.has_key?(arguments, &1)) do
          [] -> {:ok, build(name, arguments, subject)}
          missing -> {:invalid, "missing arguments: " <> Enum.join(missing, ", ")}
        end
    end
  end

  def operation(_params, _subject), do: :unknown

  defp build("hcp_queryContext", arguments, _subject),
    do: %{method: "POST", path: ["entries", "query"], query: %{}, json: arguments}

  defp build("hcp_getEntry", arguments, _subject) do
    query =
      arguments
      |> Map.take(["purpose", "purposeDescription", "version"])
      |> Map.new(fn {key, value} -> {key, to_string(value)} end)

    %{method: "GET", path: ["entries", to_string(arguments["ref"])], query: query, json: nil}
  end

  defp build("hcp_createEntry", arguments, subject) do
    entry =
      Map.merge(statement(arguments), %{
        "schema" => @entry_schema,
        "subject" => %{"id" => subject},
        "classification" => %{
          "categories" => arguments["categories"],
          "dimension" => arguments["dimension"]
        }
      })

    %{method: "POST", path: ["entries"], query: %{}, json: entry}
  end

  defp build("hcp_reviseEntry", arguments, _subject) do
    body = Map.merge(statement(arguments), Map.take(arguments, ["expectedVersion", "reason"]))
    path = ["entries", to_string(arguments["ref"]), "revisions"]
    %{method: "POST", path: path, query: %{}, json: body}
  end

  defp build("hcp_withdrawEntry", arguments, _subject) do
    query = %{"reason" => to_string(arguments["reason"])}
    %{method: "DELETE", path: ["entries", to_string(arguments["ref"])], query: query, json: nil}
  end

  defp build("hcp_reportSharing", arguments, _subject),
    do: %{method: "POST", path: ["shares"], query: %{}, json: arguments}

  # The tool's flat fields as the Core members they stand for (§10.3.3's table).
  defp statement(arguments) do
    assertion =
      %{
        "declarationType" => arguments["declarationType"],
        "confidence" => arguments["confidence"],
        "basis" => arguments["basis"],
        "permittedPurposes" => arguments["permittedPurposes"]
      }
      |> compact()

    provenance =
      %{
        "source" => arguments["sourceContext"],
        "assertedBy" => arguments["assertedBy"] && %{"id" => arguments["assertedBy"]}
      }
      |> compact()

    %{
      "content" => %{"profile" => @general_context, "value" => arguments["content"]},
      "assertion" => assertion,
      "record" => %{"provenance" => provenance}
    }
  end

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  # Outcomes → tool results (§10.3, §10.4) -------------------------------------------------

  @doc """
  The tool result for an operation's outcome. A success is returned in
  `structuredContent`, with the same JSON in a text block. A Core error is a
  tool execution error carrying its code as `type` and a `detail`.
  """
  @spec tool_result(rpc(), response(), MapSet.t()) :: response()
  def tool_result(rpc, {status, body, _type, _headers}, faults) when status in 200..299 do
    structured = body || %{}
    text = %{"type" => "text", "text" => Jason.encode!(structured)}

    content =
      if MapSet.member?(faults, :mcp_text_only),
        do: %{"content" => [text]},
        else: %{"structuredContent" => structured, "content" => [text]}

    result(rpc, Map.put(content, "isError", false))
  end

  def tool_result(rpc, {_status, %{"type" => type} = problem, _type, _headers}, _faults),
    do: tool_error(rpc, type |> String.split("/") |> List.last(), problem["detail"] || "")

  @doc "A tool execution error carrying a Core error (§10.4)."
  @spec tool_error(rpc(), String.t(), String.t()) :: response()
  def tool_error(rpc, code, detail) do
    result(rpc, %{
      "isError" => true,
      "structuredContent" => %{"type" => code, "detail" => detail},
      "content" => [%{"type" => "text", "text" => "#{code}: #{detail}"}]
    })
  end

  @doc """
  The challenge for a denial that follows from the request alone (§10.4): the
  scopes the request needs, and the purpose code where purpose alone was the
  reason, which a challenge has no parameter for.
  """
  @spec challenge(String.t(), [String.t()], String.t()) :: {String.t(), String.t()}
  def challenge(base, scopes, description) do
    value =
      ~s(Bearer error="insufficient_scope", scope="#{Enum.join(scopes, " ")}", ) <>
        ~s(resource_metadata="#{metadata_url(base)}", error_description="#{description}")

    {"www-authenticate", value}
  end

  @doc "The challenge on a request with missing or invalid authorization."
  @spec unauthenticated(String.t()) :: {String.t(), String.t()}
  def unauthenticated(base),
    do: {"www-authenticate", ~s(Bearer resource_metadata="#{metadata_url(base)}")}

  @doc "Where the provider's OAuth 2.0 Protected Resource Metadata is published (RFC 9728)."
  @spec metadata_url(String.t()) :: String.t()
  def metadata_url(base), do: base <> "/.well-known/oauth-protected-resource"
end
