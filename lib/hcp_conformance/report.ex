defmodule HcpConformance.Report do
  @moduledoc """
  The outcome of a run, as a plain map that encodes to JSON as-is.

  The verdict is about the MUST checks:

  - `pass`: every MUST check that applies passed, and none was skipped
  - `fail`: at least one MUST check failed
  - `incomplete`: nothing failed, but some MUST checks were skipped or could not
    run, so conformance is not established

  Checks that do not apply to the target by its own declaration (`na`, such as
  MCP checks for a REST-only implementation) do not affect the verdict.
  """

  alias HcpConformance.{Config, Context, Transcript}

  @suite_version Mix.Project.config()[:version]
  @spec_version "1.0-draft-4"

  @spec suite_version() :: String.t()
  def suite_version, do: @suite_version

  @spec spec_version() :: String.t()
  def spec_version, do: @spec_version

  @spec build(Context.t(), [map()], DateTime.t()) :: map()
  def build(ctx, results, started_at) do
    %{
      suite: %{version: @suite_version, spec_version: @spec_version},
      target: Config.public(ctx.config),
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      verdict: verdict(results),
      partial: ctx.config.groups != nil or ctx.config.only != nil,
      summary: summary(results),
      groups: group_summaries(results),
      capabilities: ctx.capabilities |> MapSet.to_list() |> Enum.sort(),
      setup_notes: Enum.map(ctx.setup_notes, &Transcript.redact(ctx.transcript, &1)),
      discovery: ctx.discovery,
      categories: %{
        primary: ctx.primary_category,
        second: ctx.second_category,
        outside: ctx.outside_category
      },
      results: results,
      transcript: ctx.transcript |> Transcript.exchanges() |> Enum.map(&serializable/1)
    }
  end

  # Headers are tuples in the transcript; JSON wants pairs.
  defp serializable(exchange) do
    exchange
    |> Map.update!(:request_headers, &Enum.map(&1, fn {name, value} -> [name, value] end))
    |> Map.update!(:response_headers, &Enum.map(&1, fn {name, value} -> [name, value] end))
  end

  @spec verdict([map()]) :: String.t()
  def verdict(results) do
    must = Enum.filter(results, &(&1.level == :must))

    cond do
      Enum.any?(must, &(&1.status == :fail)) -> "fail"
      Enum.any?(must, &(&1.status in [:skip, :error])) -> "incomplete"
      true -> "pass"
    end
  end

  defp summary(results) do
    for level <- [:must, :should], into: %{} do
      {level, counts(Enum.filter(results, &(&1.level == level)))}
    end
  end

  defp group_summaries(results) do
    results
    |> Enum.group_by(& &1.group)
    |> Enum.map(fn {group, items} -> %{group: group, counts: counts(items)} end)
  end

  defp counts(results) do
    base = %{pass: 0, fail: 0, warn: 0, skip: 0, error: 0, na: 0}
    Enum.reduce(results, base, fn result, acc -> Map.update!(acc, result.status, &(&1 + 1)) end)
  end

  @doc "A plain-text rendering for terminals and CI logs."
  @spec to_text(map(), keyword()) :: String.t()
  def to_text(report, opts \\ []) do
    verbose = Keyword.get(opts, :verbose) == true
    exchanges = Map.new(report.transcript, &{&1.id, &1})

    header = [
      "HCP conformance suite #{report.suite.version} (spec #{report.suite.spec_version})",
      "Target:   #{report.target.target} (#{report.target.mode} mode)",
      "Verdict:  #{String.upcase(report.verdict)}#{if report.partial, do: " (selected checks only, not a conformance claim)", else: ""}",
      "MUST:     #{format_counts(report.summary.must)}",
      "SHOULD:   #{format_counts(report.summary.should)}"
    ]

    notes = Enum.map(report.setup_notes, &("Setup:    " <> &1))

    lines =
      Enum.flat_map(report.results, fn result ->
        line =
          "#{mark(result.status)} #{result.id} [§#{result.section} #{String.upcase(to_string(result.level))}] #{result.title}"

        detail = if result.message, do: ["      " <> result.message], else: []

        trace =
          if verbose and result.status in [:fail, :warn, :error] do
            Enum.flat_map(result.exchanges, &format_exchange(exchanges[&1]))
          else
            []
          end

        [line | detail ++ trace]
      end)

    Enum.join(header ++ notes ++ [""] ++ lines, "\n") <> "\n"
  end

  defp format_exchange(nil), do: []

  defp format_exchange(exchange) do
    status = exchange.status || "ERR"
    body = (exchange.response_body || exchange.error || "") |> String.slice(0, 400)
    ["        #{exchange.method} #{exchange.url} -> #{status}", "          #{body}"]
  end

  defp format_counts(counts),
    do:
      "#{counts.pass} passed, #{counts.fail} failed, #{counts.warn} warnings, #{counts.skip} skipped, #{counts.error} errors, #{counts.na} not applicable"

  defp mark(:pass), do: "  PASS "
  defp mark(:fail), do: "  FAIL "
  defp mark(:warn), do: "  WARN "
  defp mark(:skip), do: "  SKIP "
  defp mark(:error), do: "  ERROR"
  defp mark(:na), do: "  N/A  "
end
