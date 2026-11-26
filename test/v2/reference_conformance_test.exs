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

  test "an MCP-only target: the MCP checks run, and what needs the HTTP Binding does not apply" do
    target = ReferenceTarget.start!(version: "2.0", bindings: ["mcp"])
    {:ok, report} = HcpConformance.run(ReferenceTarget.hook_config(target))

    assert ReferenceTarget.failures(report, [:fail, :error, :warn, :skip]) == ""
    assert report.verdict == "pass"
    assert :rest not in report.capabilities and :mcp in report.capabilities

    statuses = Map.new(report.results, &{&1.id, &1.status})
    # A tool call needs nothing but the grant.
    assert statuses["mcp.query"] == :pass
    assert statuses["mcp.get_entry"] == :pass
    assert statuses["mcp.revise"] == :pass
    assert statuses["mcp.category_challenge"] == :pass
    assert statuses["mcp.existence_hidden"] == :pass
    # The governance plane is carried by the HTTP Binding alone.
    assert statuses["grants.revocation"] == :na
    assert statuses["audit.event_structure"] == :na
    assert statuses["mcp.create"] == :na
    assert statuses["mcp.audited"] == :na
  end

  test "a target that does not claim the Memory Manager Profile: what needs an inference does not apply" do
    target = ReferenceTarget.start!(version: "2.0", memory_manager: false)

    {:ok, report} =
      HcpConformance.run(ReferenceTarget.hook_config(target, %{groups: ["entries", "conflicts"]}))

    assert ReferenceTarget.failures(report, [:fail, :error, :warn, :skip]) == ""
    statuses = Map.new(report.results, &{&1.id, &1.status})

    assert statuses["entries.inferred_requires_profile"] == :pass
    assert statuses["conflicts.quarantine"] == :na
    assert statuses["conflicts.detected"] == :na
    # A conflict between two of the person's own statements is Core's, whatever is claimed.
    assert statuses["conflicts.own_statements"] == :pass
    assert statuses["conflicts.target_unreadable"] == :pass
    assert %{message: message} = Enum.find(report.results, &(&1.id == "conflicts.quarantine"))
    assert message =~ "Memory Manager Profile"
  end

  test "a provider whose method does not find the suite's contradiction is not failed for it" do
    target = ReferenceTarget.start!(version: "2.0", detects: false)

    {:ok, report} =
      HcpConformance.run(ReferenceTarget.hook_config(target, %{groups: ["conflicts"]}))

    assert ReferenceTarget.failures(report, [:fail, :error, :warn, :skip]) == ""
    assert report.verdict == "pass"
    statuses = Map.new(report.results, &{&1.id, &1.status})

    # What follows from a detection cannot be observed without one.
    assert Enum.map(
             ~w(conflicts.detected conflicts.detection_symmetric conflicts.reevaluated),
             &statuses[&1]
           ) == [:na, :na, :na]

    # What Core fixes for a conflict a client asserts, and what no method may do, still hold.
    assert statuses["conflicts.quarantine"] == :pass
    assert statuses["conflicts.accept"] == :pass
    assert statuses["conflicts.dimension_alone"] == :pass
    assert %{message: message} = Enum.find(report.results, &(&1.id == "conflicts.detected"))
    assert message =~ "did not find"
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
