defmodule HcpConformance.FaultDetectionTest do
  # Each case switches one defect on in the reference server and proves the
  # check guarding that requirement fails, while the rest of the narrowed run
  # still passes. A check that cannot catch its defect is worse than none.
  use ExUnit.Case, async: true

  alias HcpConformance.Reference.Server
  alias HcpConformance.ReferenceTarget

  @moduletag timeout: 120_000

  # {fault, checks to run, checks that must fail}
  @cases [
    {:omit_hcp_version, ~w(entries.add responses.hcp_version), ~w(responses.hcp_version)},
    {:wrong_media_type, ~w(discovery.media_type entries.add responses.success_media_type),
     ~w(discovery.media_type responses.success_media_type)},
    {:ignore_version_header, ~w(transport.unsupported_version),
     ~w(transport.unsupported_version)},
    {:not_found_for_agent, ~w(entries.nonexistent_is_403), ~w(entries.nonexistent_is_403)},
    {:hard_delete_keeps, ~w(entries.hard_delete export.default_contents),
     ~w(entries.hard_delete export.default_contents)},
    {:no_idempotency,
     ~w(idempotency.post_replay idempotency.post_single_event idempotency.post_conflict idempotency.put_replay),
     ~w(idempotency.post_replay idempotency.post_single_event idempotency.post_conflict idempotency.put_replay)},
    {:no_purpose_check, ~w(search.requires_purpose), ~w(search.requires_purpose)},
    {:no_ceiling, ~w(search.ceiling), ~w(search.ceiling)},
    {:pad_results, ~w(search.not_padded), ~w(search.not_padded)},
    {:count_leak, ~w(search.no_counts), ~w(search.no_counts)},
    {:no_redaction, ~w(search.agent_redaction search.person_unredacted),
     ~w(search.agent_redaction)},
    {:no_conflicts, ~w(conflicts.inferred_second conflicts.declared_second conflicts.audited),
     ~w(conflicts.inferred_second conflicts.declared_second conflicts.audited)},
    {:leak_conflicted_versions, ~w(conflicts.withheld_from_agent),
     ~w(conflicts.withheld_from_agent)},
    {:revocation_ignored, ~w(grants.revocation), ~w(grants.revocation)},
    {:plain_cursor, ~w(audit.pagination audit.cursor_opaque), ~w(audit.cursor_opaque)},
    {:export_open, ~w(export.agents_refused), ~w(export.agents_refused)}
  ]

  for {fault, only, failing} <- @cases do
    test "#{fault} is caught by #{Enum.join(failing, ", ")}" do
      target = ReferenceTarget.start!(faults: [unquote(fault)])

      {:ok, report} =
        HcpConformance.run(ReferenceTarget.hook_config(target, %{only: unquote(only)}))

      statuses = Map.new(report.results, &{&1.id, &1.status})

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

  test "every fault the reference server offers has a case" do
    covered = Enum.map(@cases, &elem(&1, 0))
    assert Server.faults() -- covered == []
  end
end
