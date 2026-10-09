defmodule HcpConformance.Checks.Mcp do
  @moduledoc """
  The MCP server manifest (Appendix B), for implementations declaring the MCP
  transport. The MCP protocol exchange itself (tool calls over JSON-RPC) is not
  exercised yet.
  """

  alias HcpConformance.{Assert, Check, Context}

  @tools ~w(hcp_searchPreferences hcp_addPreference hcp_updatePreference hcp_deletePreference)

  def group, do: "mcp"

  def checks do
    [
      Check.new(
        "mcp.manifest",
        "App. B",
        :must,
        "The MCP manifest names the four HCP tools and the scope format",
        &manifest/1,
        requires: [:mcp]
      )
    ]
  end

  defp manifest(ctx) do
    url =
      ctx.endpoints.mcp_manifest ||
        Assert.fail!("MCP is declared but mcp_manifest_endpoint is missing")

    response = Context.request(ctx, :get, url, token: ctx.person_token)
    Assert.status!(response, 200, "GET mcp_manifest_endpoint")
    body = Assert.json_object!(response, "MCP manifest")

    tools =
      List.wrap(body["tools"])
      |> Enum.map(fn tool -> if is_map(tool), do: tool["name"], else: tool end)

    missing = @tools -- tools
    Assert.check!(missing == [], "the manifest lacks tools: #{inspect(missing)}")
    Assert.check!(body["authorizationRequired"] == true, "authorizationRequired must be true")

    Assert.check!(
      body["scopeFormat"] == "hcp:{category}:{action}",
      "scopeFormat must be \"hcp:{category}:{action}\""
    )
  end
end
