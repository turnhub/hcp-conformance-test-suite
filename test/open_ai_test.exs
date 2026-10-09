defmodule HcpConformance.OpenAITest do
  use ExUnit.Case, async: true

  alias HcpConformance.OpenAI
  alias HcpConformance.OpenAIStub

  @conversation [
    %{role: "user", text: "Hi"},
    %{role: "assistant", text: "Hello. How can I help?"},
    %{role: "user", text: "Which running shoes should I buy?"}
  ]

  defp settings(base_url), do: [key: "sk-test-key", model: "gpt-5.4-mini", base_url: base_url]

  test "sends the instructions and the conversation, unstored, and returns the reply's text" do
    base = OpenAIStub.start!(self(), OpenAIStub.reply("Try a stability shoe."))

    assert OpenAI.respond("Use these memories.", @conversation, settings(base)) ==
             {:ok, "Try a stability shoe."}

    assert_received {:openai_request,
                     %{
                       path: "/v1/responses",
                       authorization: ["Bearer sk-test-key"],
                       body: %{
                         "model" => "gpt-5.4-mini",
                         "instructions" => "Use these memories.",
                         "store" => false,
                         "input" => [
                           %{"role" => "user", "content" => "Hi"},
                           %{"role" => "assistant", "content" => "Hello. How can I help?"},
                           %{"role" => "user", "content" => "Which running shoes should I buy?"}
                         ]
                       }
                     }}
  end

  test "reports OpenAI's own error message, with the key taken out" do
    error = %{
      "error" => %{
        "message" => "Incorrect API key provided: sk-test-key.",
        "code" => "invalid_api_key"
      }
    }

    base = OpenAIStub.start!(self(), {401, error})

    assert OpenAI.respond("", @conversation, settings(base)) ==
             {:error, "OpenAI answered 401: Incorrect API key provided: [redacted]."}
  end

  test "an unreachable API is an error to show, not a crash" do
    assert {:error, "could not reach OpenAI: " <> _reason} =
             OpenAI.respond("", @conversation, settings("http://127.0.0.1:1/v1"))
  end
end
