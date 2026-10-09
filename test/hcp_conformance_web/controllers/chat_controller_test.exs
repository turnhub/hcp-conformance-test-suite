defmodule HcpConformanceWeb.ChatControllerTest do
  use HcpConformanceWeb.ConnCase, async: true

  test "the OpenAI key goes into the encrypted session, never into the redirect", %{conn: conn} do
    conn = post(conn, ~p"/chat/openai", openai: %{key: " sk-test ", model: "gpt-5.4-mini"})

    assert redirected_to(conn) == ~p"/chat"
    assert get_session(conn, :openai) == %{"key" => "sk-test", "model" => "gpt-5.4-mini"}
  end

  test "a blank key is refused, and a blank model means the default", %{conn: conn} do
    refused = post(conn, ~p"/chat/openai", openai: %{key: "  ", model: ""})
    assert get_session(refused, :openai) == nil
    assert Phoenix.Flash.get(refused.assigns.flash, :error) == "Enter an OpenAI API key."

    accepted = post(conn, ~p"/chat/openai", openai: %{key: "sk-test", model: ""})
    assert get_session(accepted, :openai) == %{"key" => "sk-test", "model" => "gpt-5.4-mini"}
  end

  test "forgetting the key removes it from the session", %{conn: conn} do
    conn =
      conn
      |> init_test_session(openai: %{"key" => "sk-test", "model" => "gpt-5.4-mini"})
      |> delete(~p"/chat/openai")

    assert redirected_to(conn) == ~p"/chat"
    assert get_session(conn, :openai) == nil
  end
end
