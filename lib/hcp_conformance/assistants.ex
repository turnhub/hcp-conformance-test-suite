defmodule HcpConformance.Assistants do
  @moduledoc """
  The assistants the chat page can talk to. Each is an HCP client of its own: it
  holds its own grants, so the same memory reaching both shows the memory belongs
  to the person, not to either vendor.
  """

  alias HcpConformance.{Anthropic, OpenAI}

  @type t :: %{id: String.t(), name: String.t(), vendor: String.t(), default_model: String.t()}
  @type message :: %{role: String.t(), text: String.t()}

  @assistants [
    %{id: "chatgpt", name: "ChatGPT", vendor: "OpenAI", default_model: "gpt-5.4-mini"},
    %{id: "claude", name: "Claude", vendor: "Anthropic", default_model: "claude-opus-5-5"}
  ]

  @doc "Every assistant the page offers."
  @spec all() :: [t()]
  def all, do: @assistants

  @doc "The assistant with this id, or nil."
  @spec get(String.t()) :: t() | nil
  def get(id), do: Enum.find(@assistants, &(&1.id == id))

  @doc "The assistant's reply, from its vendor's API. `opts`: `:key` and `:model`."
  @spec respond(t(), String.t(), [message()], keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def respond(%{id: "chatgpt"}, instructions, messages, opts),
    do: OpenAI.respond(instructions, messages, opts)

  def respond(%{id: "claude"}, instructions, messages, opts),
    do: Anthropic.respond(instructions, messages, opts)

  @max_words 12

  @doc """
  Asks the assistant which words to search the person's vault for, before it
  answers: the vault returns only what the words find, and a message such as
  "what do you know about me?" names nothing to find. The assistant is told how
  the vault searches and which categories its grant covers, never what is in
  the vault. Returns up to #{@max_words} lowercase words.
  """
  @spec pick_words(
          t(),
          [message()],
          %{categories: [String.t()], method: String.t() | nil},
          keyword()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  def pick_words(assistant, messages, search, opts) do
    with {:ok, answer} <-
           respond(assistant, picking_instructions(assistant, search), messages, opts) do
      case words(answer) do
        "" -> {:error, "it answered with no words"}
        words -> {:ok, words}
      end
    end
  end

  defp picking_instructions(%{name: name}, %{categories: categories, method: method}) do
    """
    You are choosing what #{name} should look up in the user's HCP memory vault \
    before answering their latest message. The vault returns only the memories your \
    search words find, from these categories: #{Enum.join(categories, ", ")}. \
    #{method_sentence(method)}

    Reply with search words only: up to #{@max_words} plain words likely to appear in \
    memories that would help answer, including synonyms and related words. For a broad \
    question about the user, include everyday words people use about themselves, such \
    as: i am my like love need prefer allergic. No punctuation, no explanation.
    """
  end

  defp method_sentence("lexical"),
    do: "Its search is lexical: a memory is found only when it contains one of your words."

  defp method_sentence(nil), do: ""
  defp method_sentence(method), do: "Its search method is #{method}."

  defp words(answer) do
    ~r/[\p{L}\p{N}']+/u
    |> Regex.scan(String.downcase(answer))
    |> List.flatten()
    |> Enum.take(@max_words)
    |> Enum.join(" ")
  end
end
