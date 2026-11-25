defmodule HcpConformanceWeb.ChatLiveV2Test do
  # The chat page against the v2 reference implementation this app serves at
  # /reference/hcp-v2, with OpenAI and Anthropic replaced by local stubs. Not
  # async: the stubs' URLs are application settings.
  use HcpConformanceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HcpConformance.AssistantStub
  alias HcpConformanceWeb.ReferenceMount

  @shoes "I need high arch support in my running shoes."
  @reply "Look for a stability shoe with firm arch support."
  @keys %{
    "chatgpt" => %{"key" => "sk-test", "model" => "gpt-5.4-mini"},
    "claude" => %{"key" => "sk-ant-test", "model" => "claude-opus-5-5"}
  }

  defp picking?(body), do: (body["instructions"] || body["system"] || "") =~ "search words"

  # The request that asked for the answer, past any that picked search words.
  defp answer_request do
    receive do
      {:assistant_request, %{body: body} = request} ->
        if picking?(body), do: answer_request(), else: request
    after
      0 -> flunk("no request asked for an answer")
    end
  end

  setup do
    previous =
      Map.new(
        [:openai_base_url, :anthropic_base_url],
        &{&1, Application.get_env(:hcp_conformance, &1)}
      )

    chatgpt = fn body ->
      AssistantStub.reply(if(picking?(body), do: "Shoes, running!", else: @reply))
    end

    claude = fn body ->
      AssistantStub.claude_reply(if(picking?(body), do: "Shoes, running!", else: @reply))
    end

    Application.put_env(:hcp_conformance, :openai_base_url, AssistantStub.start!(self(), chatgpt))

    Application.put_env(
      :hcp_conformance,
      :anthropic_base_url,
      AssistantStub.start!(self(), claude)
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:hcp_conformance, key, value) end)
    end)
  end

  defp ready(conn) do
    base = ReferenceMount.base_url() <> "/hcp-v2"

    connection = %{
      "target" => base,
      "hook_url" => base <> "/conformance-hook",
      "hook_secret" => "reference-hook-secret",
      "spec_version" => "2.0"
    }

    {:ok, view, _html} =
      conn |> init_test_session(connection: connection, assistants: @keys) |> live(~p"/chat")

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
      declaration_type: "person-declared"
    }

    submit(view, "#memory-form", memory: Map.merge(defaults, params))
  end

  defp ask(view, assistant, text) do
    submit(view, "#chat-form", chat: %{assistant: assistant, text: text, use_vault: "true"})
  end

  defp outcome(view) do
    view
    |> element("#messages .chat-start:last-child [data-role=context]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=outcome]")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
  end

  defp click(view, selector, text) do
    view |> element(selector, text) |> render_click()
    render_async(view, 30_000)
  end

  test "a v2 vault opens the chat page, which speaks its version", %{conn: conn} do
    view = ready(conn)

    assert has_element?(view, "#vault", "HCP v2 (2.0-draft-3)")
    assert has_element?(view, "#memory-form option[value=person-declared]")
    refute has_element?(view, "#memory-form option[value=user-declared]")
    # v2 has no minimal response mode: an assistant always receives a disclosure.
    refute has_element?(view, "#chat-form select[name='chat[detail]']")
  end

  test "a grant shows its scopes and the purpose the person approved, and is audited", %{
    conn: conn
  } do
    view = ready(conn)
    grant(view, "chatgpt", %{grant_type: "temporary", expires_in: "600"})

    row = view |> element("#grants tbody tr") |> render()
    assert row =~ "ChatGPT"
    assert row =~ "hcp:general_preferences:read"
    assert row =~ "Answer the person&#39;s message"
    assert row =~ "temporary"
    assert row =~ "active"

    assert has_element?(view, "#calls details:first-child", "/hcp-v2/conformance-hook/subjects/")
    assert has_element?(view, "#audit tbody tr", "grant.issued")
    assert has_element?(view, "#audit tbody tr", "the vault's authorization service")
    refute render(view) =~ "ref-grant-"
  end

  test "with a grant, the memories the question touches go to the assistant as disclosures", %{
    conn: conn
  } do
    view = ready(conn)
    remember(view, %{text: @shoes})
    grant(view, "chatgpt")

    ask(view, "chatgpt", "Which running shoes should I buy?")

    assert outcome(view) =~ "Sent 1 memory to ChatGPT"
    assert outcome(view) =~ @shoes
    assert outcome(view) =~ "usable until"

    assert has_element?(view, "#calls details:first-child", "/v2/entries/query")
    assert has_element?(view, "#audit tbody tr", "context.read")
    assert has_element?(view, "#audit tbody tr", "ChatGPT")
    %{body: %{"instructions" => instructions}} = answer_request()
    assert instructions =~ @shoes
  end

  test "revoking a grant cuts the assistant off at its next message", %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: @shoes})
    grant(view, "chatgpt")

    click(view, "#grants tbody tr button", "Revoke")

    assert has_element?(view, "#grants tbody tr", "revoked")
    assert has_element?(view, "#audit", "grant.revoked")

    ask(view, "chatgpt", "Which running shoes should I buy?")
    assert outcome(view) =~ "The vault refused ChatGPT: 401 invalid-token"
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

  test "what an assistant says the person said is unverified until the person confirms it", %{
    conn: conn
  } do
    view = ready(conn)
    remember(view, %{text: "I am vegetarian."})
    grant(view, "claude", %{write: "true"})
    remember(view, %{text: "Prefers aisle seats.", author: "claude"})

    assert has_element?(view, "#entries li:first-child", "authenticated")
    refute has_element?(view, "#entries li:first-child button", "Confirm")
    assert has_element?(view, "#entries li:last-child", "unverified")

    click(view, "#entries li:last-child button", "Confirm")

    assert has_element?(view, "#entries li:last-child", "confirmed by the person")
    refute has_element?(view, "#entries li:last-child button", "Confirm")
    assert has_element?(view, "#audit", "context.confirmed")
  end

  test "a memory the person rejects is deleted", %{conn: conn} do
    view = ready(conn)
    grant(view, "claude", %{write: "true"})
    remember(view, %{text: "Loves steak.", author: "claude"})

    click(view, "#entries li button", "Reject")

    assert has_element?(view, "#entries li", "deleted")
    refute has_element?(view, "#entries li button", "Reject")
  end

  test "an assistant's inference that contradicts the person is quarantined until the person decides",
       %{conn: conn} do
    view = ready(conn)
    remember(view, %{text: "I am vegetarian.", dimension: "diet"})
    grant(view, "claude", %{write: "true"})

    remember(view, %{
      text: "I am not vegetarian.",
      dimension: "diet",
      author: "claude",
      declaration_type: "model-inferred",
      confidence: "medium"
    })

    assert has_element?(view, "#entries li:last-child", "conflicted")
    assert has_element?(view, "#entries li:first-child", "active")
    assert has_element?(view, "#audit", "conflict.detected")

    # Accepting it is the person's act; the statement it contradicted is set aside.
    click(view, "#entries li:last-child button", "Confirm")

    assert has_element?(view, "#entries li:last-child", "active")
    assert has_element?(view, "#entries li:last-child", "confirmed by the person")
    assert has_element?(view, "#entries li:first-child", "deprecated")
    assert has_element?(view, "#audit", "conflict.resolved")
  end
end
