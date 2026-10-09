defmodule HcpConformanceWeb.ChatControllerTest do
  use HcpConformanceWeb.ConnCase, async: true

  test "a key goes into the encrypted session under its assistant, never into the redirect", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/chat/keys", key: %{assistant: "claude", key: " sk-ant-test ", model: ""})

    assert redirected_to(conn) == ~p"/chat"

    assert get_session(conn, :assistants) == %{
             "claude" => %{"key" => "sk-ant-test", "model" => "claude-opus-5-5"}
           }
  end

  test "keys for both assistants are kept side by side", %{conn: conn} do
    conn =
      conn
      |> init_test_session(
        assistants: %{"claude" => %{"key" => "sk-ant", "model" => "claude-opus-5-5"}}
      )
      |> post(~p"/chat/keys", key: %{assistant: "chatgpt", key: "sk-test", model: "gpt-5.4-mini"})

    assert %{"claude" => %{"key" => "sk-ant"}, "chatgpt" => %{"key" => "sk-test"}} =
             get_session(conn, :assistants)
  end

  test "a blank key or an unknown assistant is refused", %{conn: conn} do
    blank = post(conn, ~p"/chat/keys", key: %{assistant: "chatgpt", key: "  ", model: ""})
    assert get_session(blank, :assistants) == nil
    assert Phoenix.Flash.get(blank.assigns.flash, :error) == "Enter an API key."

    unknown = post(conn, ~p"/chat/keys", key: %{assistant: "eliza", key: "k", model: ""})
    assert get_session(unknown, :assistants) == nil
  end

  test "forgetting a key removes only that assistant's", %{conn: conn} do
    conn =
      conn
      |> init_test_session(
        assistants: %{
          "chatgpt" => %{"key" => "sk-test", "model" => "gpt-5.4-mini"},
          "claude" => %{"key" => "sk-ant", "model" => "claude-opus-5-5"}
        }
      )
      |> delete(~p"/chat/keys/chatgpt")

    assert redirected_to(conn) == ~p"/chat"
    assert Map.keys(get_session(conn, :assistants)) == ["claude"]
  end
end
