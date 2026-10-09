defmodule HcpConformance.ReferenceConformanceTest do
  # The suite against its own reference implementation: every check must pass a
  # conformant target, in every mode the suite offers.
  use ExUnit.Case, async: true

  alias HcpConformance.ReferenceTarget

  @moduletag timeout: 300_000

  setup do
    {:ok, target: ReferenceTarget.start!()}
  end

  test "hook mode: every check passes, and only MCP is not applicable", %{target: target} do
    {:ok, report} = HcpConformance.run(ReferenceTarget.hook_config(target))

    assert ReferenceTarget.failures(report, [:fail, :error, :warn, :skip]) == ""
    assert %{verdict: "pass"} = report
    assert [%{id: "mcp.manifest"}] = Enum.filter(report.results, &(&1.status == :na))
  end

  test "static mode: no failures, and checks needing the hook are skipped", %{target: target} do
    token = ReferenceTarget.person_token!(target)
    {:ok, report} = HcpConformance.run(%{target: target.base, person_token: token, allow_private: true})

    assert ReferenceTarget.failures(report) == ""
    assert %{verdict: "incomplete"} = report
    skipped = report.results |> Enum.filter(&(&1.status == :skip)) |> Enum.map(& &1.id)
    assert "grants.revocation" in skipped
    assert "conflicts.inferred_second" in skipped
    assert %{status: :pass} = Enum.find(report.results, &(&1.id == "entries.hard_delete"))
  end

  test "anonymous mode: discovery and transport checks run without credentials", %{target: target} do
    {:ok, report} = HcpConformance.run(%{target: target.base, allow_private: true})

    assert ReferenceTarget.failures(report) == ""
    assert %{status: :pass} = Enum.find(report.results, &(&1.id == "discovery.required_members"))
    assert %{status: :pass} = Enum.find(report.results, &(&1.id == "transport.unsupported_version"))
    assert %{verdict: "incomplete"} = report
  end

  test "the report encodes as JSON with credentials redacted", %{target: target} do
    config = ReferenceTarget.hook_config(target, %{groups: ["discovery", "entries"]})
    {:ok, report} = HcpConformance.run(config)
    json = Jason.encode!(report)

    refute json =~ target.hook_secret
    refute json =~ "ref-person-"
    refute json =~ "ref-grant-"
    assert json =~ "[redacted]"
  end
end
