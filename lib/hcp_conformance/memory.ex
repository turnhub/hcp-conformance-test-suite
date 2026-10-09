defmodule HcpConformance.Memory do
  @moduledoc """
  Memory portability, shown on a real target: the chat page reads a person's
  memories from their HCP vault the way any assistant would, as an agent holding
  a grant, and hands ChatGPT the ones the current message touches.

  It reuses the suite's run context: discovery, endpoints, the private-network
  guard, and a transcript that redacts every credential. With a conformance hook
  it works in a fresh subject with an agent grant on one category, deleted again
  by `close/1`. With an agent token it reads and writes the vault that token is
  for.
  """

  alias HcpConformance.{Config, Context, Fixtures, HTTP, Transcript}

  @enforce_keys [:context]
  defstruct [:context]

  @type t :: %__MODULE__{context: Context.t()}

  @purpose "Personalise a conversation with ChatGPT"

  @doc "Connects to the vault as an agent; a connection without one cannot recall anything."
  @spec connect(Config.t()) :: {:ok, t()} | {:error, String.t()}
  def connect(%Config{} = config) do
    case Context.start(config) do
      %Context{agent: %{token: token}} = context when is_binary(token) ->
        {:ok, %__MODULE__{context: context}}

      context ->
        close(%__MODULE__{context: context})
        {:error, "cannot act as an agent on this target: " <> why_not(context)}
    end
  end

  @doc """
  Ties the connection to the calling process (the chat page), so its helper
  processes stop with it rather than with the task that connected.
  """
  @spec link(t()) :: :ok
  def link(%__MODULE__{context: context}) do
    Process.link(context.transcript)
    Process.link(context.state)
    :ok
  end

  @doc "Disposes of the hook subject, if any, and stops the connection's processes."
  @spec close(t()) :: :ok
  def close(%__MODULE__{context: context}) do
    Context.finish(context)
    Enum.each([context.transcript, context.state], &stop/1)
  end

  @doc "The categories the agent's grant lets it read."
  @spec categories(t()) :: [String.t()]
  def categories(%__MODULE__{context: %{agent: agent}}) do
    for "hcp:" <> scope <- agent.scopes,
        String.ends_with?(scope, ":read"),
        do: String.replace_suffix(scope, ":read", "")
  end

  @doc "The memories in the agent's categories that `query` touches, as the vault returns them."
  @spec recall(t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def recall(%__MODULE__{context: context} = memory, query) do
    body = %{
      "categories" => categories(memory),
      "purpose" => @purpose,
      "query" => query,
      "maxEntries" => 10,
      "responseDetail" => "full"
    }

    case send_as_agent(context, :search, body) do
      %{status: 200, json: %{"entries" => entries}} when is_list(entries) -> {:ok, entries}
      response -> {:error, refusal("search", response)}
    end
  rescue
    error in HTTP.TransportError -> {:error, Exception.message(error)}
  end

  @doc "Saves `text` to the vault as a user-declared memory in the agent's first category."
  @spec remember(t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def remember(%__MODULE__{context: context} = memory, text) do
    body = Fixtures.entry_body(context, preference: text, category: hd(categories(memory)))

    case send_as_agent(context, :preferences, body) do
      %{status: 201, json: %{} = entry} -> {:ok, entry}
      response -> {:error, refusal("saving the memory", response)}
    end
  rescue
    error in HTTP.TransportError -> {:error, Exception.message(error)}
  end

  @doc "A memory's statement, in either envelope form (§2.2.1)."
  @spec preference(map()) :: String.t()
  def preference(%{"claim" => %{"subject" => %{"preference" => preference}}}),
    do: text(preference)

  def preference(%{"subject" => %{"preference" => preference}}), do: text(preference)
  def preference(_entry), do: ""

  @doc "A memory's category, in either envelope form."
  @spec category(map()) :: String.t() | nil
  def category(%{"record" => %{"category" => category}}), do: category
  def category(entry), do: entry["category"]

  @doc """
  The instructions ChatGPT gets: the recalled memories, where they came from, and
  how to use them. With none, it is told so, so it does not guess.
  """
  @spec instructions([map()]) :: String.t()
  def instructions([]) do
    """
    You are ChatGPT. No memories from the user's HCP vault apply to this message. \
    Answer without assuming anything about the user.
    """
  end

  def instructions(entries) do
    memories =
      Enum.map_join(entries, "\n", &"- #{preference(&1)} (#{category(&1)}, #{declaration(&1)})")

    """
    You are ChatGPT. The user keeps their memories in their own HCP vault (Human \
    Context Protocol), not in ChatGPT. These were retrieved from it for this message, \
    through a grant the user issued:

    #{memories}

    Use them where they help, and say when you rely on one. Do not invent others.
    """
  end

  defp send_as_agent(context, endpoint, body) do
    Context.request(context, :post, Context.url(context, endpoint),
      token: context.agent.token,
      json: body
    )
  end

  defp refusal(what, %{status: status, body: body}),
    do: "#{what} answered #{status}: " <> Transcript.excerpt(body, 300)

  defp why_not(%Context{setup_notes: []}),
    do: "connect with a conformance hook, or with an agent token"

  defp why_not(%Context{setup_notes: notes}), do: Enum.join(notes, "; ")

  defp declaration(%{"record" => %{"declarationType" => declaration}}), do: declaration
  defp declaration(entry), do: entry["declarationType"]

  defp text(preference) when is_binary(preference), do: preference
  defp text(preference), do: Jason.encode!(preference)

  defp stop(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
