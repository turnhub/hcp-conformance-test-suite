defmodule HcpConformance.V2.ReferenceConformanceTest do
  # The v2 checks against the v2 reference implementation: every check must pass
  # a conformant target, in every mode the suite offers.
  use ExUnit.Case, async: true

  alias HcpConformance.{Catalog, ReferenceTarget}

  @moduletag timeout: 300_000

  setup do
    {:ok, target: ReferenceTarget.start!(version: "2.0")}
  end

  test "the version is read from the discovery document", %{target: target} do
    {:ok, report} =
      HcpConformance.run(ReferenceTarget.hook_config(target, %{groups: ["discovery"]}))

    assert report.suite.spec_version == "2.0-draft-3"

    assert Enum.map(report.results, & &1.id) ==
             Enum.map(Catalog.select("2.0", ["discovery"], nil), & &1.id)
  end

  test "hook mode: every v2 check passes", %{target: target} do
    {:ok, report} = HcpConformance.run(ReferenceTarget.hook_config(target))

    assert ReferenceTarget.failures(report, [:fail, :error, :warn, :skip, :na]) == ""
    assert %{verdict: "pass"} = report
    assert length(report.results) == length(Catalog.all("2.0"))
  end

  test "static mode: no failures, and checks needing the hook are skipped", %{target: target} do
    # A v2 entry names its Context Subject, so a run with supplied tokens is told who that is.
    subject = ReferenceTarget.subject!(target)

    {:ok, report} =
      HcpConformance.run(Map.merge(subject, %{target: target.base, allow_private: true}))

    assert ReferenceTarget.failures(report) == ""
    assert %{verdict: "incomplete"} = report
    skipped = report.results |> Enum.filter(&(&1.status == :skip)) |> Enum.map(& &1.id)
    assert "grants.revocation" in skipped
    assert %{status: :pass} = Enum.find(report.results, &(&1.id == "entries.hard_delete"))
  end

  test "anonymous mode: discovery and transport checks run without credentials", %{target: target} do
    {:ok, report} = HcpConformance.run(%{target: target.base, allow_private: true})

    assert ReferenceTarget.failures(report) == ""
    assert %{status: :pass} = Enum.find(report.results, &(&1.id == "discovery.claims"))

    assert %{status: :pass} =
             Enum.find(report.results, &(&1.id == "transport.unsupported_version"))

    assert %{verdict: "incomplete"} = report
  end

  test "a v1 run against a v2 target fails its discovery checks rather than passing", %{
    target: target
  } do
    config = ReferenceTarget.hook_config(target, %{spec_version: "1.0", groups: ["discovery"]})
    {:ok, report} = HcpConformance.run(config)

    assert report.suite.spec_version == "1.0-draft-4"
    assert report.verdict == "fail"
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
