defmodule HcpConformanceWeb.ChatLiveTest do
  # The chat page against the reference implementation this app serves at
  # /reference, with OpenAI replaced by a local stub. Not async: the stub's URL is
  # an application setting.
  use HcpConformanceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HcpConformance.OpenAIStub
  alias HcpConformanceWeb.ReferenceMount

  @shoes "I need high arch support in my running shoes."
  @reply "Look for a stability shoe with firm arch support."

  setup do
    previous = Application.get_env(:hcp_conformance, :openai_base_url)
    base = OpenAIStub.start!(self(), OpenAIStub.reply(@reply))
    Application.put_env(:hcp_conformance, :openai_base_url, base)
    on_exit(fn -> Application.put_env(:hcp_conformance, :openai_base_url, previous) end)
  end

  defp session(conn, openai) do
    base = ReferenceMount.base_url()

    init_test_session(conn,
      connection: %{
        "target" => base,
        "hook_url" => base <> "/conformance-hook",
        "hook_secret" => "reference-hook-secret"
      },
      openai: openai
    )
  end

  defp ready(conn) do
    {:ok, view, _html} =
      live(session(conn, %{"key" => "sk-test", "model" => "gpt-5.4-mini"}), ~p"/chat")

    render_async(view, 30_000)
    view
  end

  defp remember(view, text) do
    view |> form("#remember-form", memory: %{text: text}) |> render_submit()
    render_async(view, 30_000)
  end

  defp ask(view, text, use_memory) do
    view
    |> form("#chat-form", chat: %{text: text, use_memory: to_string(use_memory)})
    |> render_submit()

    render_async(view, 30_000)
  end

  test "without a connection, the chat page sends you to connect", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/chat")
  end

  test "without an OpenAI key, it asks for one and keeps it out of the page", %{conn: conn} do
    {:ok, view, _html} = live(session(conn, nil), ~p"/chat")

    assert has_element?(view, "#openai-form")
    refute has_element?(view, "#chat-form")
  end

  test "connects to the vault as an agent and names the category it reads", %{conn: conn} do
    view = ready(conn)

    assert has_element?(view, "#vault", "general_preferences")
    refute render(view) =~ "sk-test"
  end

  test "a memory saved to the vault reaches ChatGPT when the question touches it", %{conn: conn} do
    view = ready(conn)
    remember(view, @shoes)
    assert has_element?(view, "#saved li", @shoes)

    ask(view, "Which running shoes should I buy?", true)

    assert has_element?(view, "#messages .chat-end", "Which running shoes should I buy?")
    assert has_element?(view, "#messages .chat-start", @reply)
    assert has_element?(view, "#messages [data-role=context]", @shoes)

    assert_received {:openai_request,
                     %{body: %{"instructions" => instructions, "input" => input}}}

    assert instructions =~ @shoes
    assert input == [%{"role" => "user", "content" => "Which running shoes should I buy?"}]
  end

  test "with memory off, ChatGPT gets nothing from the vault", %{conn: conn} do
    view = ready(conn)
    remember(view, @shoes)

    ask(view, "Which running shoes should I buy?", false)

    assert has_element?(view, "#messages [data-role=context]", "Memory off")
    assert_received {:openai_request, %{body: %{"instructions" => instructions}}}
    refute instructions =~ @shoes
  end

  test "the conversation so far goes with each message", %{conn: conn} do
    view = ready(conn)
    ask(view, "Hello", true)
    ask(view, "And again", true)

    assert_received {:openai_request, %{body: %{"input" => [%{"content" => "Hello"}]}}}

    assert_received {:openai_request,
                     %{
                       body: %{
                         "input" => [
                           %{"role" => "user", "content" => "Hello"},
                           %{"role" => "assistant", "content" => @reply},
                           %{"role" => "user", "content" => "And again"}
                         ]
                       }
                     }}
  end
end
