defmodule HcpConformanceWeb.BasicAuthTest do
  use HcpConformanceWeb.ConnCase, async: false

  setup do
    Application.put_env(:hcp_conformance, :basic_auth, "user:pass")
    on_exit(fn -> Application.delete_env(:hcp_conformance, :basic_auth) end)
  end

  test "protects the runner and the API, but not health or the reference implementation", %{
    conn: conn
  } do
    assert conn |> get(~p"/") |> response(401)
    assert build_conn() |> get(~p"/api/checks") |> response(401)

    authorized =
      put_req_header(
        build_conn(),
        "authorization",
        Plug.BasicAuth.encode_basic_auth("user", "pass")
      )

    assert authorized |> get(~p"/") |> html_response(200)

    assert build_conn() |> get(~p"/health") |> text_response(200) == "ok"
    assert build_conn() |> get("/reference/.well-known/hcp-configuration") |> json_response(200)
  end
end
