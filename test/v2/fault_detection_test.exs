defmodule HcpConformance.V2.FaultDetectionTest do
  # Each case switches one defect on in the v2 reference server and proves the
  # check guarding that requirement fails, while the rest of the narrowed run
  # still passes.
  use ExUnit.Case, async: true

  alias HcpConformance.Reference.ServerV2
  alias HcpConformance.ReferenceTarget

  @moduletag timeout: 120_000

  # {fault, checks to run, checks that must fail}
  @cases [
    {:omit_version_header, ~w(entries.create responses.version_header),
     ~w(responses.version_header)},
    {:ignore_version_header, ~w(transport.unsupported_version transport.supported_version),
     ~w(transport.unsupported_version)},
    {:trust_provenance, ~w(entries.create entries.provider_sets_provenance),
     ~w(entries.provider_sets_provenance)},
    {:accept_inferred, ~w(entries.inferred_requires_confidence entries.inferred_requires_profile),
     ~w(entries.inferred_requires_profile)},
    {:leak_id, ~w(entries.create entries.disclosure entries.ref_opaque), ~w(entries.disclosure)},
    {:ref_shared, ~w(entries.ref_opaque entries.ref_grant_scoped), ~w(entries.ref_grant_scoped)},
    {:long_use_until, ~w(entries.disclosure entries.use_until), ~w(entries.use_until)},
    {:not_found_for_client, ~w(entries.get entries.nonexistent_is_403),
     ~w(entries.nonexistent_is_403)},
    {:no_purpose_check, ~w(query.response query.purpose_bound), ~w(query.purpose_bound)},
    {:pad_results, ~w(query.default_max query.not_padded), ~w(query.not_padded)},
    {:no_ceiling, ~w(query.default_max query.ceiling), ~w(query.ceiling)},
    {:count_leak, ~w(query.not_paginated query.no_counts), ~w(query.no_counts)},
    {:no_idempotency,
     ~w(entries.create idempotency.create_replay idempotency.create_single_event idempotency.create_conflict idempotency.revision_replay),
     ~w(idempotency.create_replay idempotency.create_single_event idempotency.create_conflict idempotency.revision_replay)},
    {:stale_confirmation, ~w(governance.confirm governance.confirm_version_conflict),
     ~w(governance.confirm_version_conflict)},
    {:hard_delete_keeps, ~w(entries.withdraw entries.hard_delete export.default_contents),
     ~w(entries.hard_delete export.default_contents)},
    {:revocation_ignored, ~w(grants.revocation_audited grants.revocation grants.relinquish),
     ~w(grants.revocation grants.relinquish)},
    {:governance_open,
     ~w(audit.event_structure governance.refused.audit governance.refused.export governance.refused.confirm),
     ~w(governance.refused.audit governance.refused.export governance.refused.confirm)},
    {:rule_ignored, ~w(rules.set rules.other_operators_unaffected rules.enforced),
     ~w(rules.enforced)},
    {:no_directives, ~w(directives.set directives.delivered), ~w(directives.delivered)},
    {:plain_cursor, ~w(audit.pagination audit.cursor_opaque), ~w(audit.cursor_opaque)},
    {:share_unrecorded, ~w(sharing.report sharing.not_permitted), ~w(sharing.not_permitted)},
    {:mcp_missing_tool, ~w(mcp.discover mcp.tools), ~w(mcp.tools)},
    {:mcp_governance_tool, ~w(mcp.tools mcp.no_governance_tools), ~w(mcp.no_governance_tools)},
    {:mcp_text_only, ~w(mcp.unknown_tool mcp.query), ~w(mcp.query)},
    {:mcp_no_challenge,
     ~w(mcp.existence_hidden mcp.category_challenge mcp.purpose_challenge mcp.write_challenge),
     ~w(mcp.category_challenge mcp.purpose_challenge mcp.write_challenge)},
    {:mcp_existence_challenge, ~w(mcp.get_entry mcp.existence_hidden), ~w(mcp.existence_hidden)},
    {:mcp_token_echo, ~w(mcp.query mcp.token_not_returned), ~w(mcp.token_not_returned)}
  ]

  for {fault, only, failing} <- @cases do
    test "#{fault} is caught by #{Enum.join(failing, ", ")}" do
      target = ReferenceTarget.start!(version: "2.0", faults: [unquote(fault)])

      {:ok, report} =
        HcpConformance.run(ReferenceTarget.hook_config(target, %{only: unquote(only)}))

      statuses = Map.new(report.results, &{&1.id, &1.status})

      assert map_size(statuses) == length(unquote(only)),
             "a check named here is not in the v2 catalogue"

      for id <- unquote(failing) do
        assert statuses[id] in [:fail, :warn],
               "#{id} did not catch #{unquote(fault)}: #{inspect(statuses[id])}"
      end

      passing = unquote(only) -- unquote(failing)
      unexpected = Enum.reject(passing, &(statuses[&1] == :pass))

      assert unexpected == [],
             "checks that should still pass did not:\n" <> ReferenceTarget.failures(report)

      assert report.verdict == "fail"
    end
  end

  test "every fault the v2 reference server offers has a case" do
    covered = Enum.map(@cases, &elem(&1, 0))
    assert ServerV2.faults() -- covered == []
  end
end
