defmodule HcpConformance.V2.Checks.Transport do
  @moduledoc """
  HTTP Binding mechanics every endpoint shares (§9.3, §9.7): protocol version
  negotiation and bearer authentication. The per-response requirements are
  checked over the whole run by `HcpConformance.V2.Checks.Responses`.
  """

  alias HcpConformance.{Assert, Check, Context}
  alias HcpConformance.V2.{Fixtures, Target}

  def group, do: "transport"

  def checks do
    [
      Check.new(
        "transport.unsupported_version",
        "9.3",
        :must,
        "A request naming an unsupported HCP-Version is refused with 400 unsupported-version",
        &unsupported_version/1,
        requires: [:rest]
      ),
      Check.new(
        "transport.supported_version",
        "9.3",
        :must,
        "A request naming the published version is served",
        &supported_version/1,
        requires: [:rest]
      ),
      Check.new(
        "transport.missing_token",
        "9.7",
        :must,
        "A request without a bearer token is refused with 401 invalid-token",
        &missing_token/1,
        requires: [:rest]
      ),
      Check.new(
        "transport.invalid_token",
        "9.7",
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
        Context.request(ctx, :post, Context.url(ctx, :query),
          token: token,
          headers: headers,
          json: body(ctx)
        )
    end
  end

  defp body(ctx),
    do: %{
      "query" => "conformance",
      "categories" => [ctx.primary_category],
      "purpose" => Target.purpose()
    }

  defp unsupported_version(ctx) do
    ctx
    |> version_request("99.0")
    |> Assert.problem!(400, "unsupported-version", "HCP-Version: 99.0")
  end

  defp supported_version(ctx) do
    response = version_request(ctx, "2.0")

    Assert.check!(
      response.status in 200..299,
      "HCP-Version: 2.0 was answered with #{response.status}#{Assert.body_hint(response)}"
    )
  end

  defp missing_token(ctx) do
    response = Context.request(ctx, :post, Context.url(ctx, :query), json: body(ctx))
    Assert.problem!(response, 401, "invalid-token", "a query without Authorization")
  end

  defp invalid_token(ctx) do
    token = "hcp-conformance-forged-" <> Context.random_word(24)
    response = Fixtures.query(ctx, token, %{"query" => "conformance"})
    Assert.problem!(response, 401, "invalid-token", "a query with a forged token")
  end
end
