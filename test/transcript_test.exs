defmodule HcpConformance.TranscriptTest do
  use ExUnit.Case, async: true

  alias HcpConformance.{ReferenceTarget, Transcript}

  @moduletag timeout: 120_000

  defp exchange(overrides) do
    Map.merge(
      %{
        check_id: "test",
        kind: :target,
        method: "GET",
        url: "https://vault.example.com/v1/audit",
        request_headers: [
          {"authorization", "Bearer abcdef123456"},
          {"accept", "application/json"}
        ],
        request_body: nil,
        status: 200,
        response_headers: [
          {"set-cookie", "session=abc123secret"},
          {"content-type", "application/json"}
        ],
        response_body: ~s({"token":"live-secret-value"}),
        facts: nil,
        error: nil,
        duration_ms: 1
      },
      overrides
    )
  end

  test "the listener receives each exchange already redacted, headers both ways included" do
    test = self()
    {:ok, transcript} = Transcript.start_link(on_exchange: &send(test, {:exchange, &1}))
    Transcript.add_secret(transcript, "live-secret-value")

    %{id: 1} = Transcript.record(transcript, exchange(%{}))

    assert_received {:exchange,
                     %{
                       request_headers: [
                         {"authorization", "Bearer [redacted]"},
                         {"accept", "application/json"}
                       ],
                       response_headers: [
                         {"set-cookie", "[redacted]"},
                         {"content-type", "application/json"}
                       ],
                       response_body: ~s({"token":"[redacted]"})
                     }}
  end

  test "bodies stay valid UTF-8: cut on a character boundary, binary replaced by a note" do
    {:ok, transcript} = Transcript.start_link()
    long = String.duplicate("é", 10_000)

    %{response_body: cut} = Transcript.record(transcript, exchange(%{response_body: long}))
    assert String.valid?(cut)
    assert String.ends_with?(cut, "…[truncated]")

    %{response_body: note} =
      Transcript.record(transcript, exchange(%{response_body: <<0xFF, 0xFE, 0x00>>}))

    assert note == "[binary body, 3 bytes]"
  end

  test "no live event of a hook run carries a token the hook handed out" do
    target = ReferenceTarget.start!()
    test = self()
    on_event = fn event -> send(test, event) end

    {:ok, _report} =
      HcpConformance.run(ReferenceTarget.hook_config(target, %{groups: ["discovery", "grants"]}),
        on_event: on_event
      )

    exchanges = collect([])
    encoded = Jason.encode!(exchanges)

    assert length(exchanges) > 10
    refute encoded =~ "ref-person-"
    refute encoded =~ "ref-grant-"
    refute encoded =~ target.hook_secret
  end

  defp collect(acc) do
    receive do
      {:exchange, exchange} -> collect([exchange | acc])
      _other -> collect(acc)
    after
      0 -> acc
    end
  end
end
