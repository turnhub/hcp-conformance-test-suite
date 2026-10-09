defmodule HcpConformanceWeb.PageControllerTest do
  use HcpConformanceWeb.ConnCase, async: true

  test "the catalogue lists every check", %{conn: conn} do
    document = conn |> get(~p"/checks") |> html_response(200) |> LazyHTML.from_document()
    rows = LazyHTML.query(document, "#checks tr")
    assert Enum.count(rows) == length(HcpConformance.Catalog.all())
  end

  test "the hook page shows the protocol", %{conn: conn} do
    document = conn |> get(~p"/hook") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#hook-spec") |> LazyHTML.text() =~
             "POST {hook_url}/subjects"
  end
end
