defmodule HcpConformance.V2.Checks.Responses do
  @moduledoc """
  Requirements on every response of the HTTP Binding (§9.3, §9.7, §9.8), judged
  over the transcript of the whole run once the other checks have finished.
  """

  alias HcpConformance.{Assert, Check, Transcript}

  # Core error → status → problem type (§9.7). 409 and 422 each carry one of two.
  @registered %{
    400 => ["unsupported-version"],
    401 => ["invalid-token"],
    403 => ["scope-denied"],
    409 => ["idempotency-conflict", "version-conflict"],
    422 => ["malformed-request", "credential-invalid"],
    429 => ["rate-limited"],
    503 => ["subject-unavailable"]
  }
  @json ["application/ld+json", "application/json"]

  def group, do: "responses"

  def checks do
    post = [requires: [:rest], phase: :post, evidence: :run]

    [
      Check.new(
        "responses.version_header",
        "9.3",
        :must,
        "Every response carries an HCP-Version header matching the discovery document",
        &version_header/1,
        post
      ),
      Check.new(
        "responses.success_media_type",
        "9.3",
        :must,
        "Successful responses with a body are JSON: application/ld+json, or application/json as the examples show",
        &success_media_type/1,
        post
      ),
      Check.new(
        "responses.problem_format",
        "9.7",
        :must,
        "Error responses are application/problem+json with type, title, status and detail",
        &problem_format/1,
        post
      ),
      Check.new(
        "responses.problem_types",
        "9.7",
        :must,
        "Errors use the registered problem type for their status",
        &problem_types/1,
        post
      ),
      Check.new(
        "responses.retry_after",
        "9.8",
        :must,
        "Every 429 response carries Retry-After",
        &retry_after/1,
        post
      ),
      Check.new(
        "responses.no_server_errors",
        "9.7",
        :should,
        "The target never answered with a 5xx",
        &no_server_errors/1,
        post
      )
    ]
  end

  # Responses from the target's HCP surface: not the hook, and only ones that arrived.
  defp responses(ctx) do
    ctx.transcript
    |> Transcript.exchanges()
    |> Enum.filter(&(&1.kind == :target and is_integer(&1.status)))
  end

  defp facts(exchange), do: exchange.facts || %{object: false}

  defp header(exchange, name),
    do: Enum.find_value(exchange.response_headers, fn {key, value} -> key == name && value end)

  defp content_type(exchange) do
    case header(exchange, "content-type") do
      nil -> nil
      value -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    end
  end

  defp report!(offenders, what) do
    sample =
      offenders
      |> Enum.take(3)
      |> Enum.map_join("; ", fn {exchange, why} ->
        "#{exchange.method} #{exchange.url} -> #{exchange.status}: #{why}"
      end)

    Assert.check!(offenders == [], "#{length(offenders)} #{what}, e.g. #{sample}")
  end

  defp version_header(ctx) do
    expected = (ctx.discovery || %{})["hcp_version"] || "2.0"

    ctx
    |> responses()
    |> Enum.reject(&(header(&1, "hcp-version") == expected))
    |> Enum.map(&{&1, "HCP-Version is #{inspect(header(&1, "hcp-version"))}"})
    |> report!("responses without HCP-Version: #{expected}")
  end

  defp success_media_type(ctx) do
    ctx
    |> responses()
    |> Enum.filter(&(&1.status in 200..299 and (&1.response_body || "") != ""))
    |> Enum.reject(&(content_type(&1) in @json))
    |> Enum.map(&{&1, "content-type #{inspect(content_type(&1))}"})
    |> report!("successful responses not served as JSON")
  end

  defp errors(ctx), do: ctx |> responses() |> Enum.filter(&(&1.status in 400..599))

  defp problem_format(ctx) do
    ctx
    |> errors()
    |> Enum.flat_map(&format_problems/1)
    |> report!("error responses not in RFC 9457 problem format")
  end

  defp format_problems(exchange) do
    facts = facts(exchange)
    missing = ["type", "title", "status", "detail"] -- Map.get(facts, :members, [])

    cond do
      content_type(exchange) != "application/problem+json" ->
        [{exchange, "content-type #{inspect(content_type(exchange))}"}]

      not facts.object ->
        [{exchange, "the body is not a JSON object"}]

      missing != [] ->
        [{exchange, "missing #{Enum.join(missing, ", ")}"}]

      facts.status != exchange.status ->
        [
          {exchange,
           "status member #{inspect(facts.status)} differs from HTTP #{exchange.status}"}
        ]

      true ->
        []
    end
  end

  defp problem_types(ctx) do
    base = (ctx.discovery || %{})["problem_type_base"] || "https://hcp.example/problems/"

    ctx
    |> errors()
    |> Enum.filter(&Map.has_key?(@registered, &1.status))
    |> Enum.reject(
      &(Map.get(facts(&1), :type) in Enum.map(@registered[&1.status], fn slug -> base <> slug end))
    )
    |> Enum.map(
      &{&1,
       "type #{inspect(Map.get(facts(&1), :type))}, expected #{base}#{Enum.join(@registered[&1.status], " or ")}"}
    )
    |> report!("errors without the registered problem type")
  end

  defp retry_after(ctx) do
    ctx
    |> responses()
    |> Enum.filter(&(&1.status == 429 and is_nil(header(&1, "retry-after"))))
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
