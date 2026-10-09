defmodule HcpConformance.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias HcpConformance.{CLI, ReferenceTarget}

  @moduletag timeout: 120_000

  test "a passing run prints the report, writes JSON and exits 0" do
    target = ReferenceTarget.start!()
    json = Path.join(System.tmp_dir!(), "hcp-cli-#{System.unique_integer([:positive])}.json")

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          args = [
            "--target",
            target.base,
            "--hook-url",
            target.hook_url,
            "--hook-secret",
            target.hook_secret,
            "--allow-private",
            "--json",
            json
          ]

          send(self(), {:status, CLI.run(args)})
        end)
      end)

    assert_received {:status, 0}
    assert output =~ "Verdict:  PASS"
    assert output =~ "PASS  entries.add"
    assert %{"verdict" => "pass"} = json |> File.read!() |> Jason.decode!()
  end

  test "a failing run exits 1 and --verbose shows the exchanges" do
    target = ReferenceTarget.start!(faults: [:not_found_for_agent])

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          args = [
            "--target",
            target.base,
            "--hook-url",
            target.hook_url,
            "--hook-secret",
            target.hook_secret,
            "--allow-private",
            "--verbose",
            "--only",
            "entries.nonexistent_is_403"
          ]

          send(self(), {:status, CLI.run(args)})
        end)
      end)

    assert_received {:status, 1}
    assert output =~ "FAIL  entries.nonexistent_is_403"
    assert output =~ "-> 404"
  end

  test "a usage error exits 2" do
    capture_io(:stderr, fn -> send(self(), {:status, CLI.run(["--bogus"])}) end)
    assert_received {:status, 2}
  end
end
