defmodule HcpConformanceWeb.V2Test do
  # The web layer with a v2 target: the v2 reference this app serves inside
  # /reference, the connect page, the run page, the catalogue and the API.
  use HcpConformanceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HcpConformance.Catalog
  alias HcpConformanceWeb.ReferenceMount

  @moduletag timeout: 120_000

  defp connection do
    base = ReferenceMount.base_url() <> "/hcp-v2"

    %{
      "target" => base,
      "hook_url" => base <> "/conformance-hook",
      "hook_secret" => "reference-hook-secret",
      "spec_version" => "2.0"
    }
  end

  test "the v2 reference is served inside /reference, with its own base URL", %{conn: conn} do
    body = conn |> get("/reference/hcp-v2/.well-known/hcp-configuration") |> json_response(200)

    assert %{"hcp_version" => "2.0", "provider" => provider, "entries_endpoint" => entries} = body
    assert provider == ReferenceMount.base_url() <> "/hcp-v2"
    assert entries == provider <> "/v2/entries"
    # The v1 reference next to it is unchanged.
    assert %{"hcp_version" => "1.0"} =
             build_conn() |> get("/reference/.well-known/hcp-configuration") |> json_response(200)
  end

  test "a run reaches the v2 reference on loopback with private targets refused" do
    Application.put_env(:hcp_conformance, :allow_private_targets, false)
    on_exit(fn -> Application.put_env(:hcp_conformance, :allow_private_targets, true) end)
    local = ReferenceMount.local_url("2.0")

    {:ok, config} =
      HcpConformance.Runs.config(%{
        "target" => local,
        "hook_url" => local <> "/conformance-hook",
        "hook_secret" => "reference-hook-secret",
        "groups" => ["discovery", "entries"]
      })

    assert {:ok, %{verdict: "pass", suite: %{spec_version: "2.0-draft-3"}}} =
             HcpConformance.Runs.run(config)
  end

  test "the connect page offers a reference of each version and a version to pick", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert ["2.0"] ==
             document
             |> LazyHTML.query("#reference-form-v2 input[name='connection[spec_version]']")
             |> LazyHTML.attribute("value")

    assert [ReferenceMount.local_url("2.0")] ==
             document
             |> LazyHTML.query("#reference-form-v2 input[name='connection[target]']")
             |> LazyHTML.attribute("value")

    options =
      LazyHTML.query(document, "#connect-form select[name='connection[spec_version]'] option")

    assert LazyHTML.attribute(options, "value") == ["1.0", "2.0"]
  end

  test "connecting with a version keeps it, and an unknown one is refused", %{conn: conn} do
    conn = post(conn, ~p"/session", %{"connection" => connection()})
    assert redirected_to(conn) == ~p"/run"
    assert get_session(conn, :connection)["spec_version"] == "2.0"

    refused =
      post(build_conn(), ~p"/session", %{
        "connection" => Map.put(connection(), "spec_version", "9")
      })

    assert html_response(refused, 422) =~ "spec_version"
  end

  test "the run page lists the v2 groups and runs the v2 checks", %{conn: conn} do
    {:ok, view, _html} = conn |> init_test_session(connection: connection()) |> live(~p"/run")
    total = length(Catalog.all("2.0"))

    assert has_element?(view, "#spec-version", "HCP v2 (2.0-draft-3)")
    assert has_element?(view, "#selection", "#{total} of #{total} checks")
    assert has_element?(view, "label[for=group-governance]")
    refute has_element?(view, "label[for=group-search]")

    groups = Map.new(Catalog.groups("2.0"), &{&1, to_string(&1 in ["discovery", "governance"])})
    view |> form("#run-form", run: %{groups: groups}) |> render_submit()
    html = render_async(view, 60_000)

    assert html =~ "governance.refused.audit"
    assert has_element?(view, "#verdict", "PASS")
  end

  test "the catalogue page and the API show the version asked for", %{conn: conn} do
    document =
      conn |> get(~p"/checks?spec_version=2.0") |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, "#checks tr")) == length(Catalog.all("2.0"))
    refute Enum.empty?(LazyHTML.query(document, "#checks-v2.tab-active"))

    assert %{"spec_version" => "2.0-draft-3", "checks" => checks} =
             build_conn() |> get(~p"/api/checks?spec_version=2.0") |> json_response(200)

    assert length(checks) == length(Catalog.all("2.0"))

    assert %{"spec_version" => "1.0-draft-4"} =
             build_conn() |> get(~p"/api/checks") |> json_response(200)

    assert build_conn() |> get(~p"/api/checks?spec_version=9") |> json_response(422)
  end

  test "an API run names its version, or has it read from the target", %{conn: conn} do
    body = Map.put(connection(), "groups", ["discovery", "transport"])

    assert %{"verdict" => "pass", "suite" => %{"spec_version" => "2.0-draft-3"}} =
             conn |> post(~p"/api/runs", body) |> json_response(200)

    detected =
      build_conn() |> post(~p"/api/runs", Map.delete(body, "spec_version")) |> json_response(200)

    assert %{"verdict" => "pass", "suite" => %{"spec_version" => "2.0-draft-3"}} = detected
  end
end
