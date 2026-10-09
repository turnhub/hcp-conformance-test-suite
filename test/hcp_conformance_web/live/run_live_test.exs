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

  test "the HTTP log streams every exchange, headers and bodies both ways, redacted", %{
    conn: conn
  } do
    {:ok, view, _html} = live(connected(conn), ~p"/run")

    view |> form("#run-form", run: %{groups: only(["discovery", "entries"])}) |> render_submit()
    render_async(view, 60_000)

    view |> element("#tab-log") |> render_click()
    refute has_element?(view, "#log-panel.hidden")
    assert has_element?(view, "#results-panel.hidden")

    html = view |> element("#exchanges") |> render()
    document = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(document, "details")) > 10

    assert html =~ "authorization: Bearer [redacted]"
    assert html =~ "content-type: application/ld+json"
    assert html =~ "POST /reference/v1/preferences"
    assert html =~ "&quot;hcp_version&quot;: &quot;1.0&quot;"
    refute html =~ "ref-person-"
    refute html =~ "ref-grant-"
    refute html =~ "reference-hook-secret"
  end

  test "a failing target lists its findings with the HTTP exchanges", %{conn: conn} do
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
    assert has_element?(view, "#finding-entries-nonexistent_is_403", "404")
    refute render(view) =~ target.hook_secret
  end
end
