defmodule HcpConformanceWeb.ChatLiveTest do
  # The chat page against the reference implementation this app serves at
  # /reference, with OpenAI and Anthropic replaced by local stubs. Not async: the
  # stubs' URLs are application settings.
  use HcpConformanceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HcpConformance.AssistantStub
  alias HcpConformanceWeb.ReferenceMount

  @shoes "I need high arch support in my running shoes."
  @chatgpt_reply "Look for a stability shoe with firm arch support."
  @claude_reply "A stability shoe would suit you."

  setup do
    previous =
      Map.new(
        [:openai_base_url, :anthropic_base_url],
        &{&1, Application.get_env(:hcp_conformance, &1)}
      )

    Application.put_env(
      :hcp_conformance,
      :openai_base_url,
      AssistantStub.start!(self(), AssistantStub.reply(@chatgpt_reply))
    )

    Application.put_env(
      :hcp_conformance,
      :anthropic_base_url,
      AssistantStub.start!(self(), AssistantStub.claude_reply(@claude_reply))
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:hcp_conformance, key, value) end)
    end)
  end

  defp session(conn, assistants) do
    base = ReferenceMount.base_url()

    init_test_session(conn,
      connection: %{
        "target" => base,
        "hook_url" => base <> "/conformance-hook",
        "hook_secret" => "reference-hook-secret"
      },
      assistants: assistants
    )
  end

  @both %{
    "chatgpt" => %{"key" => "sk-test", "model" => "gpt-5.4-mini"},
    "claude" => %{"key" => "sk-ant-test", "model" => "claude-opus-5-5"}
  }

  defp ready(conn, assistants \\ @both) do
    {:ok, view, _html} = live(session(conn, assistants), ~p"/chat")
    render_async(view, 30_000)
    view
  end

  defp submit(view, form, params) do
    view |> form(form, params) |> render_submit()
    render_async(view, 30_000)
  end

  defp grant(view, assistant, params \\ %{}) do
    defaults = %{
      assistant: assistant,
      categories: ["general_preferences"],
      read: "true",
      write: "false",
      grant_type: "persistent"
    }

    submit(view, "#grant-form", grant: Map.merge(defaults, params))
  end

  defp remember(view, params) do
    defaults = %{
      author: "person",
      category: "general_preferences",
      declaration_type: "user-declared"
    }

    submit(view, "#memory-form", memory: Map.merge(defaults, params))
  end

  defp ask(view, assistant, text, params \\ %{}) do
    defaults = %{assistant: assistant, text: text, use_vault: "true"}
    submit(view, "#chat-form", chat: Map.merge(defaults, params))
  end

  defp last_context(view) do
    view |> element("#messages .chat-start:last-child [data-role=context]") |> render()
  end

  test "without a connection, the chat page sends you to connect", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/chat")
  end

  test "the vault starts with no grants: nothing is shared until the person grants it", %{
    conn: conn
  } do
    view = ready(conn)

    assert has_element?(view, "#vault", "Connected as the person")
    assert has_element?(view, "#grants", "No grants yet")
    refute render(view) =~ "sk-test"
  end

  test "without keys, it asks for one per assistant", %{conn: conn} do
    view = ready(conn, %{})

    assert has_element?(view, "#key-form-chatgpt")
    assert has_element?(view, "#key-form-claude")
    refute has_element?(view, "#chat-form")
  end

  test "issuing a grant lists it, shows the HCP call that made it, and audits it", %{conn: conn} do
    view = ready(conn)

    grant(view, "chatgpt", %{
      categories: ["general_preferences", "health_context"],
      grant_type: "temporary",
      expires_in: "600"
    })

    row = view |> element("#grants tbody tr") |> render()
    assert row =~ "ChatGPT"
    assert row =~ "hcp:general_preferences:read"
    assert row =~ "hcp:health_context:read"
    assert row =~ "temporary"
    assert row =~ "active"

    assert has_element?(view, "#calls details:first-child", "Grant ChatGPT access")
    assert has_element?(view, "#calls details:first-child", "/conformance-hook/subjects/")
    assert has_element?(view, "#audit", "grant.issued")
    refute render(view) =~ "ref-grant-"
  end

  test "an assistant without a grant gets nothing from the vault, and says so", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})

    ask(view, "chatgpt", "Which running shoes should I buy?")

    assert has_element?(view, "#messages .chat-start", @chatgpt_reply)
    assert last_context(view) =~ "ChatGPT holds no grant"
    assert_received {:assistant_request, %{body: %{"instructions" => instructions}}}
    refute instructions =~ @shoes
  end

  test "with a grant, the memories the question touches go to the assistant", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})
    grant(view, "chatgpt")

    ask(view, "chatgpt", "Which running shoes should I buy?")

    assert last_context(view) =~ @shoes
    assert has_element?(view, "#calls details:first-child", "ChatGPT searched the vault")
    assert has_element?(view, "#calls details:first-child", "/v1/preferences/search")
    assert has_element?(view, "#audit", "preference.read")
    assert_received {:assistant_request, %{body: %{"instructions" => instructions}}}
    assert instructions =~ @shoes
  end

  test "revoking a grant cuts the assistant off at its next message", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})
    grant(view, "chatgpt")

    view |> element("#grants tbody tr button", "Revoke") |> render_click()
    render_async(view, 30_000)

    assert has_element?(view, "#grants tbody tr", "revoked")
    assert has_element?(view, "#audit", "grant.revoked")

    ask(view, "chatgpt", "Which running shoes should I buy?")

    assert last_context(view) =~ "The vault refused ChatGPT: 401 invalid-token"
    assert_received {:assistant_request, %{body: %{"instructions" => instructions}}}
    refute instructions =~ @shoes
  end

  test "searching outside the grant is refused by the vault, not by this page", %{conn: conn} do
    view = ready(conn)
    grant(view, "chatgpt")

    ask(view, "chatgpt", "What is my diet?", %{categories: ["health_context"]})

    assert last_context(view) =~ "The vault refused ChatGPT: 403 scope-denied"
  end

  test "a grant narrowed to one memory says so", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})

    [entry_id] =
      view
      |> element("#entries")
      |> render()
      |> then(&Regex.scan(~r/data-entry="([^"]+)"/, &1, capture: :all_but_first))
      |> List.flatten()

    grant(view, "chatgpt", %{restrict_to: [entry_id]})

    assert has_element?(view, "#grants tbody tr", "narrowed to 1 memory")
  end

  test "an assistant's inference that contradicts the person is quarantined", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: "I am vegetarian.", dimension: "diet"})
    grant(view, "claude", %{write: "true"})

    remember(view, %{
      text: "Loves steak.",
      dimension: "diet",
      author: "claude",
      declaration_type: "model-inferred",
      confidence: "medium"
    })

    assert has_element?(view, "#entries li", "Loves steak.")
    assert has_element?(view, "#entries li:last-child", "conflicted")
    assert has_element?(view, "#audit", "conflict.detected")
  end

  test "the same memory reaches a second assistant through its own grant", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})
    grant(view, "claude")

    ask(view, "claude", "Which running shoes should I buy?")

    assert has_element?(view, "#messages .chat-start", @claude_reply)
    assert last_context(view) =~ @shoes
    assert_received {:assistant_request, %{path: "/v1/messages", body: %{"system" => system}}}
    assert system =~ @shoes
  end

  test "with the vault off, nothing is asked of it", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})
    grant(view, "chatgpt")

    ask(view, "chatgpt", "Which running shoes should I buy?", %{use_vault: "false"})

    assert last_context(view) =~ "Vault off"
    refute has_element?(view, "#calls", "searched the vault")
  end

  test "export downloads the whole vault as JSON", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})

    view |> element("#export") |> render_click()
    render_async(view, 30_000)

    assert_push_event(view, "download", %{filename: "hcp-vault-export.json", content: content})
    assert %{"entries" => [_entry]} = Jason.decode!(content)
  end
end
