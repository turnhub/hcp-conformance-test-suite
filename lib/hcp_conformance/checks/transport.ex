defmodule HcpConformance.Checks.Transport do
  @moduledoc """
  RESTful transport mechanics that every endpoint shares (§3.4): protocol version
  negotiation and bearer authentication. The per-response requirements
  (`hcp_version`, media types, problem bodies) are checked over the whole run by
  `HcpConformance.Checks.Responses`.
  """

  alias HcpConformance.{Assert, Check, Context}

  def group, do: "transport"

  def checks do
    [
      Check.new(
        "transport.unsupported_version",
        "3.4.1",
        :must,
        "A request naming an unsupported HCP-Version is refused with 400 unsupported-version",
        &unsupported_version/1,
        requires: [:rest]
      ),
      Check.new(
        "transport.supported_version",
        "3.4.1",
        :must,
        "A request naming the published version is served",
        &supported_version/1,
        requires: [:rest]
      ),
      Check.new(
        "transport.missing_token",
        "3.4.4",
        :must,
        "A request without a bearer token is refused with 401 invalid-token",
        &missing_token/1,
        requires: [:rest]
      ),
      Check.new(
        "transport.invalid_token",
        "3.4.4",
        :must,
        "A request with a forged bearer token is refused with 401 invalid-token",
        &invalid_token/1,
        requires: [:rest]
      )
    ]
  end

  defp version_request(ctx, version) do
    headers = [{"hcp-version", version}]

    case ctx.person_token do
      nil ->
        Context.request(ctx, :get, Context.url(ctx, :discovery), headers: headers)

      token ->
        Context.request(ctx, :post, Context.url(ctx, :search),
          token: token,
          headers: headers,
          json: %{
            "query" => "conformance",
            "categories" => [ctx.primary_category],
            "purpose" => "HCP conformance check"
          }
        )
    end
  end

  defp unsupported_version(ctx) do
    response = version_request(ctx, "99.0")
    Assert.problem!(response, 400, "unsupported-version", "HCP-Version: 99.0")
  end

  defp supported_version(ctx) do
    response = version_request(ctx, "1.0")

    Assert.check!(
      response.status in 200..299,
      "HCP-Version: 1.0 was answered with #{response.status}#{Assert.body_hint(response)}"
    )
  end

  defp missing_token(ctx) do
    response = Context.request(ctx, :post, Context.url(ctx, :search), json: search_body(ctx))
    Assert.problem!(response, 401, "invalid-token", "search without Authorization")
  end

  defp invalid_token(ctx) do
    token = "hcp-conformance-forged-" <> Context.random_word(24)

    response =
      Context.request(ctx, :post, Context.url(ctx, :search), token: token, json: search_body(ctx))

    Assert.problem!(response, 401, "invalid-token", "search with a forged token")
  end

  defp search_body(ctx),
    do: %{
      "query" => "conformance",
      "categories" => [ctx.primary_category],
      "purpose" => "HCP conformance check"
    }
end
