defmodule HcpConformanceWeb.PageControllerTest do
  use HcpConformanceWeb.ConnCase, async: true

  test "the catalogue lists every check", %{conn: conn} do
    document = conn |> get(~p"/checks") |> html_response(200) |> LazyHTML.from_document()
    rows = LazyHTML.query(document, "#checks tr")
    assert Enum.count(rows) == length(HcpConformance.Catalog.all())
  end

  test "the hook page renders docs/HOOK.md rather than showing its source", %{conn: conn} do
    document = conn |> get(~p"/hook") |> html_response(200) |> LazyHTML.from_document()
    spec = LazyHTML.query(document, "#hook-spec")

    assert spec |> LazyHTML.query("h2") |> Enum.map(&LazyHTML.text/1) == [
             "Authentication",
             "Base URL",
             "POST {hook_url}/subjects",
             "POST {hook_url}/subjects/{subjectId}/grants",
             "DELETE {hook_url}/subjects/{subjectId}",
             "What the suite does with it"
           ]

    assert spec |> LazyHTML.query("table.table") |> Enum.count() == 3
    refute LazyHTML.text(spec) =~ "## "
  end
end
