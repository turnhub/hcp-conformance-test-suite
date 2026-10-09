defmodule HcpConformanceWeb.ApiControllerTest do
  use HcpConformanceWeb.ConnCase, async: false

  alias HcpConformanceWeb.ReferenceMount

  @moduletag timeout: 120_000

  defp reference do
    base = ReferenceMount.base_url()

    %{
      "target" => base,
      "hook_url" => base <> "/conformance-hook",
      "hook_secret" => "reference-hook-secret"
    }
  end

  test "a run answers with the report", %{conn: conn} do
    conn = post(conn, ~p"/api/runs", Map.put(reference(), "groups", ["discovery", "transport"]))

    assert %{"verdict" => "pass", "partial" => true, "results" => [_ | _]} =
             json_response(conn, 200)
  end

  test "an invalid run is refused with the reason", %{conn: conn} do
    assert %{"error" => error} =
             conn |> post(~p"/api/runs", %{"target" => "nope"}) |> json_response(422)

    assert error =~ "URL"
  end

  test "a full instance answers 429 with Retry-After", %{conn: conn} do
    previous = Application.get_env(:hcp_conformance, :max_concurrent_runs)
    Application.put_env(:hcp_conformance, :max_concurrent_runs, 0)
    on_exit(fn -> Application.put_env(:hcp_conformance, :max_concurrent_runs, previous) end)

    conn = post(conn, ~p"/api/runs", reference())
    assert json_response(conn, 429)
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "the catalogue and health check", %{conn: conn} do
    assert %{"checks" => checks} = conn |> get(~p"/api/checks") |> json_response(200)
    assert length(checks) == length(HcpConformance.Catalog.all())
    assert build_conn() |> get(~p"/health") |> text_response(200) == "ok"
  end
end
