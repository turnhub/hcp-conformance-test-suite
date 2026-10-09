defmodule HcpConformance.AnthropicTest do
  use ExUnit.Case, async: true

  alias HcpConformance.{Anthropic, AssistantStub}

  @conversation [
    %{role: "user", text: "Hi"},
    %{role: "assistant", text: "Hello. How can I help?"},
    %{role: "user", text: "Which running shoes should I buy?"}
  ]

  defp settings(base_url),
    do: [key: "sk-ant-test-key", model: "claude-opus-5-5", base_url: base_url]

  test "sends the system prompt and the conversation, and returns the text blocks" do
    base = AssistantStub.start!(self(), AssistantStub.claude_reply("Try a stability shoe."))

    assert Anthropic.respond("Use these memories.", @conversation, settings(base)) ==
             {:ok, "Try a stability shoe."}

    assert_received {:assistant_request, %{path: "/v1/messages", headers: headers, body: body}}

    assert %{
             "x-api-key" => "sk-ant-test-key",
             "anthropic-version" => "2023-06-01",
             "anthropic-beta" => "server-side-fallback-2026-07-01"
           } = headers

    assert %{
             "model" => "claude-opus-5-5",
             "system" => "Use these memories.",
             "fallbacks" => "default",
             "output_config" => %{"effort" => "low"},
             "messages" => [
               %{"role" => "user", "content" => "Hi"},
               %{"role" => "assistant", "content" => "Hello. How can I help?"},
               %{"role" => "user", "content" => "Which running shoes should I buy?"}
             ]
           } = body
  end

  test "a refusal is reported as one, not as an empty answer" do
    refusal =
      {200,
       %{
         "type" => "message",
         "stop_reason" => "refusal",
         "stop_details" => %{"type" => "refusal", "category" => "cyber"},
         "content" => []
       }}

    base = AssistantStub.start!(self(), refusal)

    assert Anthropic.respond("", @conversation, settings(base)) ==
             {:error, "Claude declined to answer (cyber)"}
  end

  test "reports Anthropic's own error message, with the key taken out" do
    error = %{
      "type" => "error",
      "error" => %{
        "type" => "authentication_error",
        "message" => "invalid x-api-key sk-ant-test-key"
      }
    }

    base = AssistantStub.start!(self(), {401, error})

    assert Anthropic.respond("", @conversation, settings(base)) ==
             {:error, "Anthropic answered 401: invalid x-api-key [redacted]"}
  end

  test "an unreachable API is an error to show, not a crash" do
    assert {:error, "could not reach Anthropic: " <> _reason} =
             Anthropic.respond("", @conversation, settings("http://127.0.0.1:1/v1"))
  end
end
