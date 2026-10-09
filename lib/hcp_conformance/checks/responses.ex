defmodule HcpConformance.Checks.Responses do
  @moduledoc """
  Requirements on every REST response (§3.3, §3.4), checked over the whole
  run's transcript after all other checks: each response the target gave is
  evidence, so these checks see far more traffic than they could generate
  themselves.
  """

  alias HcpConformance.{Assert, Check, Transcript}

  @registered %{
    400 => "unsupported-version",
    401 => "invalid-token",
    403 => "scope-denied",
    409 => "idempotency-conflict",
    422 => "malformed-request",
    429 => "rate-limited"
  }

  def group, do: "responses"

  def checks do
    post = [requires: [:rest], phase: :post]

    [
      Check.new(
        "responses.hcp_version",
        "3.4.1",
        :must,
        "Every response body carries hcp_version matching the discovery document",
        &hcp_version/1,
        post
      ),
      Check.new(
        "responses.success_media_type",
        "3.3",
        :must,
        "Successful responses are application/ld+json",
        &success_media_type/1,
        post
      ),
      Check.new(
        "responses.problem_format",
        "3.4.4",
        :must,
        "Error responses are application/problem+json with type, title, status and detail",
        &problem_format/1,
        post
      ),
      Check.new(
        "responses.problem_types",
        "3.4.4",
        :must,
        "Errors use the registered problem type for their status",
        &problem_types/1,
        post
      ),
      Check.new(
        "responses.retry_after",
        "3.4.5",
        :must,
        "Every 429 response carries Retry-After",
        &retry_after/1,
        post
      ),
      Check.new(
        "responses.no_server_errors",
        "3.4.4",
        :should,
        "The target never answered with a 5xx",
        &no_server_errors/1,
        post
      )
    ]
  end

  # Responses from the target's HCP surface: not the hook, not the MCP
  # manifest, and only ones that arrived.
  defp responses(ctx) do
    ctx.transcript
    |> Transcript.exchanges()
    |> Enum.filter(&(&1.kind == :target and is_integer(&1.status) and &1.url != ctx.endpoints.mcp_manifest))
  end

  defp facts(exchange), do: exchange.facts || %{object: false}

  defp content_type(exchange) do
    Enum.find_value(exchange.response_headers, fn
      {"content-type", value} -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      _other -> nil
    end)
  end

  defp report!(offenders, what) do
    count = length(offenders)

    sample =
      offenders
      |> Enum.take(3)
      |> Enum.map_join("; ", fn {exchange, why} ->
        "#{exchange.method} #{exchange.url} -> #{exchange.status}: #{why}"
      end)

    Assert.check!(count == 0, "#{count} #{what}, e.g. #{sample}")
  end

  defp hcp_version(ctx) do
    expected = (ctx.discovery || %{})["hcp_version"] || "1.0"

    ctx
    |> responses()
    |> Enum.filter(&(&1.status != 204 and (&1.response_body || "") != ""))
    |> Enum.flat_map(fn exchange ->
      case facts(exchange) do
        %{object: true, hcp_version: ^expected} -> []
        %{object: true, hcp_version: other} -> [{exchange, "hcp_version is #{inspect(other)}"}]
        _other -> [{exchange, "the body is not a JSON object"}]
      end
    end)
    |> report!("responses without the expected hcp_version")
  end

  defp success_media_type(ctx) do
    ctx
    |> responses()
    |> Enum.filter(&(&1.status in 200..299 and &1.status != 204))
    |> Enum.reject(&(content_type(&1) == "application/ld+json"))
    |> Enum.map(&{&1, "content-type #{inspect(content_type(&1))}"})
    |> report!("successful responses not served as application/ld+json")
  end

  defp errors(ctx), do: ctx |> responses() |> Enum.filter(&(&1.status in 400..599))

  defp problem_format(ctx) do
    ctx
    |> errors()
    |> Enum.flat_map(fn exchange ->
      facts = facts(exchange)

      cond do
        content_type(exchange) != "application/problem+json" ->
          [{exchange, "content-type #{inspect(content_type(exchange))}"}]

        not facts.object ->
          [{exchange, "the body is not a JSON object"}]

        true ->
          missing_members(exchange, facts)
      end
    end)
    |> report!("error responses not in RFC 9457 problem format")
  end

  defp missing_members(exchange, facts) do
    missing = ["type", "title", "status", "detail"] -- facts.members

    cond do
      missing != [] ->
        [{exchange, "missing #{Enum.join(missing, ", ")}"}]

      facts.status != exchange.status ->
        [{exchange, "status member #{inspect(facts.status)} differs from HTTP #{exchange.status}"}]

      true ->
        []
    end
  end

  defp problem_types(ctx) do
    base = (ctx.discovery || %{})["problem_type_base"] || "https://hcp.me/problems/"

    ctx
    |> errors()
    |> Enum.filter(&Map.has_key?(@registered, &1.status))
    |> Enum.flat_map(fn exchange ->
      expected = base <> @registered[exchange.status]

      case facts(exchange) do
        %{object: true, type: ^expected} ->
          []

        %{object: true, type: type} when is_binary(type) ->
          [{exchange, "type #{inspect(type)}, expected #{inspect(expected)}"}]

        _other ->
          [{exchange, "no type member"}]
      end
    end)
    |> report!("errors without the registered problem type")
  end

  defp retry_after(ctx) do
    ctx
    |> responses()
    |> Enum.filter(&(&1.status == 429))
    |> Enum.reject(fn exchange -> Enum.any?(exchange.response_headers, &(elem(&1, 0) == "retry-after")) end)
    |> Enum.map(&{&1, "no Retry-After header"})
    |> report!("429 responses without Retry-After")
  end

  defp no_server_errors(ctx) do
    ctx
    |> responses()
    |> Enum.filter(&(&1.status >= 500))
    |> Enum.map(&{&1, "server error"})
    |> report!("server errors")
  end
end
