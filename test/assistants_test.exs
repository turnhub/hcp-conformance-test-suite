defmodule HcpConformance.AssistantsTest do
  use ExUnit.Case, async: true

  alias HcpConformance.{Assistants, AssistantStub}

  @chatgpt %{id: "chatgpt", name: "ChatGPT", vendor: "OpenAI", default_model: "gpt-5.4-mini"}
  @conversation [%{role: "user", text: "What do you know about me?"}]
  @search %{categories: ["general_preferences", "health_context"], method: "lexical"}

  defp opts(base), do: [key: "sk-test", model: "gpt-5.4-mini", base_url: base]

  test "asks the assistant for search words, telling it how the vault searches and what it may read" do
    base = AssistantStub.start!(self(), AssistantStub.reply("Diet, allergies & pregnancy; I'm"))

    assert Assistants.pick_words(@chatgpt, @conversation, @search, opts(base)) ==
             {:ok, "diet allergies pregnancy i'm"}

    assert_received {:assistant_request,
                     %{body: %{"instructions" => instructions, "input" => input}}}

    assert instructions =~ "search words"
    assert instructions =~ "lexical"
    assert instructions =~ "general_preferences, health_context"
    assert [%{"content" => "What do you know about me?"}] = input
  end

  test "keeps at most twelve words" do
    words = Enum.map_join(1..20, " ", &"word#{&1}")
    base = AssistantStub.start!(self(), AssistantStub.reply(words))

    assert {:ok, picked} = Assistants.pick_words(@chatgpt, @conversation, @search, opts(base))
    assert length(String.split(picked)) == 12
  end

  test "an answer with no words, or an error, is an error to fall back from" do
    empty = AssistantStub.start!(self(), AssistantStub.reply("!!! ???"))

    assert {:error, "it answered with no words"} =
             Assistants.pick_words(@chatgpt, @conversation, @search, opts(empty))

    failing = AssistantStub.start!(self(), {500, %{"error" => %{"message" => "overloaded"}}})

    assert {:error, "OpenAI answered 500: overloaded"} =
             Assistants.pick_words(@chatgpt, @conversation, @search, opts(failing))
  end
end
