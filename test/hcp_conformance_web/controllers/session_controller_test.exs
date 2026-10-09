defmodule HcpConformanceWeb.SessionControllerTest do
  use HcpConformanceWeb.ConnCase, async: true

  @secret "s3cret-hook-value-xyz"

  test "the connect page offers the form and the reference implementation", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    document = LazyHTML.from_document(html)

    refute Enum.empty?(LazyHTML.query(document, "#connect-form"))
    refute Enum.empty?(LazyHTML.query(document, "#reference-form"))
  end

  test "connecting keeps the credentials in an encrypted session and goes to the run", %{
    conn: conn
  } do
    params = %{
      "target" => "https://vault.example.com",
      "hook_url" => "https://vault.example.com/hook",
      "hook_secret" => @secret
    }

    conn = post(conn, ~p"/session", connection: params)

    assert redirected_to(conn) == ~p"/run"

    assert %{"target" => "https://vault.example.com", "hook_secret" => @secret} =
             get_session(conn, :connection)

    cookie = conn.resp_cookies["_hcp_conformance_key"].value
    decoded = cookie |> String.split(".") |> Enum.map(&Base.url_decode64(&1, padding: false))
    refute cookie =~ @secret

    refute Enum.any?(
             decoded,
             &(match?({:ok, plain} when is_binary(plain), &1) and elem(&1, 1) =~ @secret)
           )
  end

  test "an invalid connection is refused, and its secrets are not echoed back", %{conn: conn} do
    conn =
      post(conn, ~p"/session", connection: %{"target" => "not a url", "hook_secret" => @secret})

    html = html_response(conn, 422)

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "URL"
    refute html =~ @secret
    refute get_session(conn, :connection)
  end

  test "disconnecting drops the credentials", %{conn: conn} do
    conn =
      conn
      |> init_test_session(connection: %{"target" => "https://vault.example.com"})
      |> delete(~p"/session")

    assert redirected_to(conn) == ~p"/"
    refute get_session(conn, :connection)
  end
end
