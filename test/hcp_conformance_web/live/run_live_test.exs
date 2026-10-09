defmodule HcpConformanceWeb.RunLiveTest do
  # Runs the suite through the LiveView against the reference implementation
  # this app serves at /reference (the test endpoint listens on port 4002).
  use HcpConformanceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HcpConformance.Catalog
  alias HcpConformanceWeb.ReferenceMount

  @moduletag timeout: 120_000

  defp connected(conn) do
    base = ReferenceMount.base_url()

    init_test_session(conn,
      connection: %{
        "target" => base,
        "hook_url" => base <> "/conformance-hook",
        "hook_secret" => "reference-hook-secret"
      }
    )
  end

  defp only(groups),
    do: Map.new(Catalog.groups(), &{&1, if(&1 in groups, do: "true", else: "false")})

  test "without a connection, the run page sends you to connect", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/run")
  end

  test "the page says what the connection's mode means for the run", %{conn: conn} do
    {:ok, view, _html} = live(connected(conn), ~p"/run")

    assert has_element?(view, "#mode .badge", "hook mode")
    assert has_element?(view, "#mode", "fresh subject")
  end

  test "choosing groups shows how many checks will run; with none chosen, nothing can run", %{
    conn: conn
  } do
    {:ok, view, _html} = live(connected(conn), ~p"/run")
    assert has_element?(view, "#selection", "94 of 94 checks · 90 MUST · 4 SHOULD")
    assert has_element?(view, "label[for=group-discovery]", "10")

    view |> form("#run-form", run: %{groups: only(["discovery"])}) |> render_change()
    assert has_element?(view, "#selection", "10 of 94 checks · 9 MUST · 1 SHOULD")
    assert has_element?(view, "#selection", "not a conformance claim")

    view |> element("#select-none") |> render_click()
    assert has_element?(view, "#selection", "0 of 94 checks")
    assert has_element?(view, "#run[disabled]")

    view |> element("#select-all") |> render_click()
    assert has_element?(view, "#selection", "94 of 94 checks")
    refute has_element?(view, "#run[disabled]")
  end

  test "stats count results by status, and results are divided by group with a filter", %{
    conn: conn
  } do
    {:ok, view, _html} = live(connected(conn), ~p"/run")

    view |> form("#run-form", run: %{groups: only(["discovery", "transport"])}) |> render_submit()
    render_async(view, 60_000)

    assert view |> element("#stat-pass .stat-value") |> render() =~ "14"
    assert view |> element("#stat-fail .stat-value") |> render() =~ "0"
    assert has_element?(view, "#results #divider-discovery", "discovery")
    assert has_element?(view, "#results #divider-transport", "transport")
    assert has_element?(view, "#result-discovery-served[data-status=pass]")
    assert has_element?(view, "#result-filter #filter-not-passed")
  end

  test "a full run against the reference implementation passes", %{conn: conn} do
    {:ok, view, _html} = live(connected(conn), ~p"/run")

    view |> form("#run-form") |> render_submit()
    render_async(view, 60_000)

    assert has_element?(view, "#verdict[data-verdict=pass]")
    assert has_element?(view, "#result-entries-add")
    assert has_element?(view, "#result-responses-hcp_version")
    refute has_element?(view, "#findings")
  end

  test "a narrowed run is marked as no conformance claim, and the report downloads", %{conn: conn} do
    {:ok, view, _html} = live(connected(conn), ~p"/run")

    view |> form("#run-form", run: %{groups: only(["discovery"])}) |> render_submit()
    render_async(view, 60_000)

    assert has_element?(view, "#summary", "not a conformance claim")
    refute has_element?(view, "#result-entries-add")

    view |> element("#download-report") |> render_click()
    assert_push_event(view, "download-report", %{content: content})
    assert %{"verdict" => "pass", "partial" => true} = Jason.decode!(content)
  end

  test "each result folds in the HTTP exchanges its check made, headers and bodies, redacted", %{
    conn: conn
  } do
    {:ok, view, _html} = live(connected(conn), ~p"/run")

    view
    |> form("#run-form", run: %{groups: only(["discovery", "entries", "responses"])})
    |> render_submit()

    render_async(view, 60_000)

    served = view |> element("#result-discovery-served") |> render()
    assert served =~ "GET /reference/.well-known/hcp-configuration"
    assert served =~ "&quot;hcp_version&quot;: &quot;1.0&quot;"
    assert has_element?(view, "#result-discovery-served [data-role=request-count]", "1 request")

    assert has_element?(view, "#result-responses-hcp_version", "every response in the run")

    added = view |> element("#result-entries-add") |> render()
    assert added =~ "POST /reference/v1/preferences"
    assert added =~ "authorization: Bearer [redacted]"
    assert added =~ "content-type: application/ld+json"
    refute added =~ "GET /reference/.well-known/hcp-configuration"

    html = render(view)
    refute html =~ "ref-person-"
    refute html =~ "ref-grant-"
    refute html =~ "reference-hook-secret"
  end

  test "setup and teardown traffic gets rows of its own, in the order it happened", %{conn: conn} do
    {:ok, view, _html} = live(connected(conn), ~p"/run")

    view |> form("#run-form", run: %{groups: only(["discovery"])}) |> render_submit()
    render_async(view, 60_000)

    ids =
      view
      |> element("#results")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#results > details")
      |> LazyHTML.attribute("id")

    assert hd(ids) == "result-setup"
    assert "result-teardown" in ids
    assert has_element?(view, "#result-setup", "POST /reference/conformance-hook/subjects")
  end

  test "a failing result opens on the exchanges behind it", %{conn: conn} do
    target = HcpConformance.ReferenceTarget.start!(faults: [:not_found_for_agent])

    conn =
      init_test_session(conn,
        connection: %{
          "target" => target.base,
          "hook_url" => target.hook_url,
          "hook_secret" => target.hook_secret
        }
      )

    {:ok, view, _html} = live(conn, ~p"/run")
    view |> form("#run-form", run: %{groups: only(["entries"])}) |> render_submit()
    render_async(view, 60_000)

    assert has_element?(view, "#verdict[data-verdict=fail]")
    assert has_element?(view, "#result-entries-nonexistent_is_403[open]", "404")
    refute has_element?(view, "#result-entries-add[open]")
    refute render(view) =~ target.hook_secret
  end
end
