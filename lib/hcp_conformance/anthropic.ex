defmodule HcpConformance.Anthropic do
  @moduledoc """
  The smallest client the chat page needs for Anthropic's Messages API: one call,
  a system prompt plus the conversation so far, text back. Elixir has no
  official Anthropic SDK, so this is the raw HTTP shape.

  Requests opt into server-side fallbacks (`fallbacks: "default"`): when Claude's
  safety classifiers decline, the API retries on a model Anthropic recommends
  instead of returning the refusal. A refusal that remains is reported as one.
  Effort is `low`, which suits chat. The key is the visitor's, from their
  encrypted session; it is never logged, and is taken out of any error echoed.
  """

  @default_base_url "https://api.anthropic.com/v1"

  @doc """
  Claude's reply to `messages`, given `instructions` as the system prompt.
  `opts`: `:key` and `:model` (required), `:base_url` (the
  `:anthropic_base_url` setting, else Anthropic's).
  """
  @spec respond(String.t(), [HcpConformance.OpenAI.message()], keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def respond(instructions, messages, opts) do
    key = Keyword.fetch!(opts, :key)

    base_url =
      opts[:base_url] ||
        Application.get_env(:hcp_conformance, :anthropic_base_url, @default_base_url)

    body = %{
      model: Keyword.fetch!(opts, :model),
      max_tokens: 16_000,
      system: instructions,
      messages: Enum.map(messages, &%{role: &1.role, content: &1.text}),
      output_config: %{effort: "low"},
      fallbacks: "default"
    }

    headers = [
      {"x-api-key", key},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", "server-side-fallback-2026-07-01"}
    ]

    case Req.post(base_url <> "/messages",
           json: body,
           headers: headers,
           retry: false,
           receive_timeout: 300_000
         ) do
      {:ok, %{status: 200, body: message}} ->
        text(message)

      {:ok, %{status: status, body: error}} ->
        {:error, "Anthropic answered #{status}: " <> redact(error_message(error), key)}

      {:error, exception} ->
        {:error, "could not reach Anthropic: " <> Exception.message(exception)}
    end
  end

  # stop_reason comes first: a refusal can arrive with empty or partial content.
  @spec text(term()) :: {:ok, String.t()} | {:error, String.t()}
  defp text(%{"stop_reason" => "refusal"} = message),
    do:
      {:error,
       "Claude declined to answer (#{get_in(message, ["stop_details", "category"]) || "no category"})"}

  defp text(%{"content" => content}) when is_list(content) do
    text = for %{"type" => "text", "text" => text} <- content, into: "", do: text
    if text == "", do: {:error, "Claude answered without any text"}, else: {:ok, text}
  end

  defp text(_message), do: {:error, "Anthropic answered with an unexpected body"}

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp error_message(body), do: inspect(body, limit: 20)

  defp redact(text, key), do: String.replace(text, key, "[redacted]")
end
