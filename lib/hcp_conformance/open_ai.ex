defmodule HcpConformance.OpenAI do
  @moduledoc """
  The smallest client the chat page needs for OpenAI's Responses API: one call,
  instructions plus the conversation so far, text back.

  Requests are sent with `store: false`, so OpenAI keeps neither the conversation
  nor the memories handed to it. The key is the visitor's, from their encrypted
  session; it is never logged, and is taken out of any error OpenAI echoes.
  """

  @default_base_url "https://api.openai.com/v1"

  @type message :: %{role: String.t(), text: String.t()}

  @doc """
  The model's reply to `messages`, given `instructions`. `opts`: `:key` and
  `:model` (required), `:base_url` (the `:openai_base_url` setting, else OpenAI's).
  """
  @spec respond(String.t(), [message()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def respond(instructions, messages, opts) do
    key = Keyword.fetch!(opts, :key)

    base_url =
      opts[:base_url] ||
        Application.get_env(:hcp_conformance, :openai_base_url, @default_base_url)

    body = %{
      model: Keyword.fetch!(opts, :model),
      instructions: instructions,
      input: Enum.map(messages, &%{role: &1.role, content: &1.text}),
      store: false
    }

    case Req.post(base_url <> "/responses",
           json: body,
           auth: {:bearer, key},
           retry: false,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: response}} ->
        output_text(response)

      {:ok, %{status: status, body: response}} ->
        {:error, "OpenAI answered #{status}: " <> redact(error_message(response), key)}

      {:error, exception} ->
        {:error, "could not reach OpenAI: " <> Exception.message(exception)}
    end
  end

  # The reply is the text of the message items in `output`; reasoning items carry none.
  @spec output_text(term()) :: {:ok, String.t()} | {:error, String.t()}
  defp output_text(%{"output" => output}) when is_list(output) do
    text =
      for %{"type" => "message", "content" => content} <- output,
          %{"type" => "output_text", "text" => text} <- content,
          into: "",
          do: text

    if text == "", do: {:error, "OpenAI answered without any text"}, else: {:ok, text}
  end

  defp output_text(_response), do: {:error, "OpenAI answered with an unexpected body"}

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp error_message(body), do: inspect(body, limit: 20)

  defp redact(text, key), do: String.replace(text, key, "[redacted]")
end
