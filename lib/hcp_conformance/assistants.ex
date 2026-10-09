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
end
