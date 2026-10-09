defmodule HcpConformance.WebTest do
  # The hosted runner end to end: a real HTTP server running the suite, through
  # its API, against the reference implementation it hosts.
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  setup do
    {:ok, pid} =
      Bandit.start_link(plug: HcpConformance.Web.Endpoint, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    base = "http://127.0.0.1:#{port}"
    previous = Application.get_all_env(:hcp_conformance)

    Application.put_env(:hcp_conformance, :public_url, base)
    Application.put_env(:hcp_conformance, :allow_private_targets, true)
    Application.put_env(:hcp_conformance, :reference_hook_secret, "web-test-secret")

    on_exit(fn ->
      for key <- [
            :public_url,
            :allow_private_targets,
            :reference_hook_secret,
            :basic_auth,
            :max_concurrent_runs
          ] do
        case previous[key] do
          nil -> Application.delete_env(:hcp_conformance, key)
          value -> Application.put_env(:hcp_conformance, key, value)
        end
      end
    end)

    {:ok, base: base}
  end

  defp await_finished(base, id, attempts \\ 120) do
    run = Req.get!(base <> "/api/runs/" <> id, retry: false).body

    cond do
      run["status"] in ["finished", "failed"] -> run
      attempts == 0 -> flunk("the run did not finish: #{inspect(run["status"])}")
      true -> Process.sleep(250) && await_finished(base, id, attempts - 1)
    end
  end

  test "an API run against the hosted reference implementation passes", %{base: base} do
    reference = base <> "/reference"

    response =
      Req.post!(base <> "/api/runs",
        json: %{target: reference, hook_url: reference <> "/conformance-hook", hook_secret: "web-test-secret"},
        retry: false
      )

    assert %{status: 202, body: %{"id" => id}} = response
    assert %{"status" => "finished", "report" => %{"verdict" => "pass"}} = await_finished(base, id)

    page = Req.get!(base <> "/runs/" <> id, retry: false)
    assert %{status: 200} = page
    assert page.body =~ "PASS"
    refute page.body =~ "web-test-secret"

    assert %{status: 200, body: %{"verdict" => "pass"}} =
             Req.get!(base <> "/api/runs/#{id}/report.json", retry: false)
  end

  test "the form runs, and the home page offers the reference implementation", %{base: base} do
    home = Req.get!(base <> "/", retry: false)
    assert %{status: 200} = home
    assert home.body =~ "Run against the reference implementation"

    reference = base <> "/reference"

    response =
      Req.post!(base <> "/runs",
        form: [
          target: reference,
          hook_url: reference <> "/conformance-hook",
          hook_secret: "web-test-secret",
          "groups[]": "discovery"
        ],
        redirect: false,
        retry: false
      )

    assert %{status: 303} = response
    ["/runs/" <> id] = Req.Response.get_header(response, "location")
    assert %{"status" => "finished", "report" => %{"verdict" => "pass"}} = await_finished(base, id)
  end

  test "a failing run shows the failure and the HTTP exchanges behind it", %{base: base} do
    target = HcpConformance.ReferenceTarget.start!(faults: [:not_found_for_agent])

    response =
      Req.post!(base <> "/api/runs",
        json: %{
          target: target.base,
          hook_url: target.hook_url,
          hook_secret: target.hook_secret,
          only: ["entries.nonexistent_is_403"]
        },
        retry: false
      )

    assert %{status: 202, body: %{"id" => id}} = response
    assert %{"report" => %{"verdict" => "fail", "partial" => true}} = await_finished(base, id)

    page = Req.get!(base <> "/runs/" <> id, retry: false).body
    assert page =~ "FAIL"
    assert page =~ "HTTP exchanges"
    assert page =~ "selected checks only"
    refute page =~ target.hook_secret
  end

  test "an invalid submission is refused with the reason", %{base: base} do
    assert %{status: 422, body: %{"error" => error}} =
             Req.post!(base <> "/api/runs", json: %{target: "nope"}, retry: false)

    assert error =~ "URL"
  end

  test "private targets are refused when the deployment does not allow them", %{base: base} do
    Application.put_env(:hcp_conformance, :allow_private_targets, false)
    response = Req.post!(base <> "/api/runs", json: %{target: base <> "/reference"}, retry: false)
    assert %{status: 202, body: %{"id" => id}} = response
    run = await_finished(base, id)
    assert [note] = run["report"]["setup_notes"]
    assert note =~ "non-public"
  end

  test "basic auth protects the runner but not health or the reference server", %{base: base} do
    Application.put_env(:hcp_conformance, :basic_auth, "user:pass")
    assert %{status: 401} = Req.get!(base <> "/", retry: false)
    assert %{status: 200} = Req.get!(base <> "/", auth: {:basic, "user:pass"}, retry: false)
    assert %{status: 200} = Req.get!(base <> "/health", retry: false)
    assert %{status: 200} = Req.get!(base <> "/reference/.well-known/hcp-configuration", retry: false)
  end

  test "the catalogue is served as HTML and JSON", %{base: base} do
    assert %{status: 200, body: html} = Req.get!(base <> "/checks", retry: false)
    assert html =~ "search.ceiling"
    assert %{status: 200, body: %{"checks" => [_ | _]}} = Req.get!(base <> "/api/checks", retry: false)
    assert %{status: 200, body: hook} = Req.get!(base <> "/docs/hook", retry: false)
    assert hook =~ "POST {hook_url}/subjects"
  end
end
