defmodule HcpConformanceWeb.ReferenceMountTest do
  use HcpConformanceWeb.ConnCase, async: false

  test "the reference implementation is served at /reference with its own base URL", %{conn: conn} do
    body = conn |> get("/reference/.well-known/hcp-configuration") |> json_response(200)
    assert %{"issuer" => issuer, "hcp_version" => "1.0"} = body
    assert issuer == HcpConformanceWeb.ReferenceMount.base_url()
  end

  test "its hook reads the raw body, ahead of the parsers", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer reference-hook-secret")
      |> put_req_header("content-type", "application/json")
      |> post("/reference/conformance-hook/subjects", Jason.encode!(%{}))

    assert %{"subjectId" => _, "personToken" => _} = Jason.decode!(conn.resp_body)
    assert conn.status == 201
  end

  test "it can be switched off", %{conn: conn} do
    Application.put_env(:hcp_conformance, :reference_server, false)
    on_exit(fn -> Application.put_env(:hcp_conformance, :reference_server, true) end)

    assert conn |> get("/reference/.well-known/hcp-configuration") |> response(404)
  end
end
