defmodule HcpConformanceWeb.ChatLive do
  @moduledoc """
  Memory portability, demonstrated: a chat with ChatGPT whose memories live in
  the person's HCP vault, not in ChatGPT.

  The page connects to the target in the session as an agent (a fresh subject and
  grant through the conformance hook, or the agent token supplied). Memories saved
  here go into the vault. For each message it searches the vault with the message
  as the query, hands ChatGPT only the memories that came back, and shows them
  under the reply. Switching memory off sends the same message with none, for
  comparison.

  Like the run page it is stateless: the conversation lives in this process, the
  OpenAI key in the encrypted session cookie, and OpenAI is asked not to store
  anything (`store: false`).
  """

  use HcpConformanceWeb, :live_view

  alias HcpConformance.{Memory, OpenAI, Runs}
  alias HcpConformanceWeb.ChatController

  @impl true
  def mount(_params, %{"connection" => connection} = session, socket) when is_map(connection) do
    case Runs.config(connection) do
      {:ok, config} ->
        openai = session["openai"]

        {:ok,
         socket
         |> assign(
           page_title: "Chat",
           target: connection["target"],
           openai: openai,
           openai_form:
             to_form(%{"key" => "", "model" => ChatController.default_model()}, as: :openai),
           memory: nil,
           vault_error: nil,
           saved: [],
           messages: [],
           replying: false,
           remember_form: remember_form(),
           chat_form: chat_form(true)
         )
         |> connect_vault(config)}

      {:error, message} ->
        {:ok, socket |> put_flash(:error, message) |> redirect(to: ~p"/")}
    end
  end

  def mount(_params, _session, socket) do
    {:ok, socket |> put_flash(:info, "Connect to a target first.") |> redirect(to: ~p"/")}
  end

  defp connect_vault(%{assigns: %{openai: %{}}} = socket, config) do
    if connected?(socket),
      do: start_async(socket, :connect, fn -> Memory.connect(config) end),
      else: socket
  end

  defp connect_vault(socket, _config), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Portable memory
        <:subtitle>
          ChatGPT, with memories read from an HCP vault through an agent grant.
        </:subtitle>
        <:actions :if={@openai}>
          <.button href={~p"/chat/openai"} method="delete" id="forget-openai">
            Forget key
          </.button>
        </:actions>
      </.header>

      <.openai_form :if={!@openai} form={@openai_form} />

      <div :if={@openai} class="space-y-4">
        <.vault target={@target} memory={@memory} error={@vault_error} />

        <div :if={@memory} class="card bg-base-200">
          <div class="card-body">
            <.form for={@remember_form} id="remember-form" phx-submit="remember">
              <.input
                field={@remember_form[:text]}
                label="Save a memory to the vault"
                placeholder="I need high arch support in my running shoes."
              />
              <.button>Save to vault</.button>
            </.form>
            <ul id="saved" class="list">
              <li :for={text <- @saved} class="list-row">{text}</li>
            </ul>
          </div>
        </div>

        <div id="messages">
          <.message :for={message <- @messages} message={message} />
          <div :if={@replying} class="chat chat-start">
            <div class="chat-bubble"><span class="loading loading-dots"></span></div>
          </div>
        </div>

        <.form :if={@memory} for={@chat_form} id="chat-form" phx-submit="send">
          <.input field={@chat_form[:text]} type="textarea" label="Message" />
          <.input
            field={@chat_form[:use_memory]}
            type="checkbox"
            label="Use memories from the vault"
          />
          <.button disabled={@replying}>Send</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  defp openai_form(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <.form for={@form} id="openai-form" action={~p"/chat/openai"}>
          <.input field={@form[:key]} type="password" label="OpenAI API key" autocomplete="off" />
          <.input field={@form[:model]} label="Model" />
          <.button>Use this key</.button>
        </.form>
        <p>
          The key stays in your encrypted session cookie. Each request asks OpenAI not to
          store the conversation.
        </p>
      </div>
    </div>
    """
  end

  attr :target, :string, required: true
  attr :memory, :any, required: true
  attr :error, :string, required: true

  defp vault(assigns) do
    ~H"""
    <div id="vault">
      <div :if={@error} role="alert" class="alert alert-error">{@error}</div>
      <div :if={!@error and !@memory} class="alert">
        <span class="loading loading-spinner"></span> Connecting to the vault as an agent…
      </div>
      <div :if={@memory} class="alert alert-success">
        <span>Connected to <span class="break-all">{@target}</span> as an agent. ChatGPT may read:</span>
        <span :for={category <- Memory.categories(@memory)} class="badge">{category}</span>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true

  defp message(%{message: %{role: "user"}} = assigns) do
    ~H"""
    <div class="chat chat-end">
      <div class="chat-bubble chat-bubble-primary">{@message.text}</div>
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div class="chat chat-start">
      <div class="chat-bubble">{@message.text}</div>
      <div class="chat-footer" data-role="context">
        <.context context={@message.context} />
      </div>
    </div>
    """
  end

  attr :context, :any, required: true

  defp context(%{context: :off} = assigns), do: ~H"Memory off: nothing from the vault was sent."

  defp context(%{context: []} = assigns),
    do: ~H"No memory in the vault matched this message, so none was sent."

  defp context(assigns) do
    ~H"""
    <details class="collapse collapse-arrow bg-base-200">
      <summary class="collapse-title">
        Sent from the vault: {length(@context)} {if length(@context) == 1,
          do: "memory",
          else: "memories"}
      </summary>
      <ul class="collapse-content list">
        <li :for={entry <- @context} class="list-row">
          <div>
            {Memory.preference(entry)} <span class="badge badge-sm">{Memory.category(entry)}</span>
          </div>
        </li>
      </ul>
    </details>
    """
  end

  @impl true
  def handle_event("remember", %{"memory" => %{"text" => text}}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        memory = socket.assigns.memory
        {:noreply, start_async(socket, :remember, fn -> Memory.remember(memory, text) end)}
    end
  end

  def handle_event("send", %{"chat" => %{"text" => text} = params}, socket) do
    use_memory = params["use_memory"] == "true"

    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        messages = socket.assigns.messages ++ [%{role: "user", text: text}]
        %{memory: memory, openai: openai} = socket.assigns

        {:noreply,
         socket
         |> assign(messages: messages, replying: true, chat_form: chat_form(use_memory))
         |> start_async(:reply, fn -> answer(memory, openai, messages, use_memory) end)}
    end
  end

  @impl true
  def handle_async(:connect, {:ok, {:ok, memory}}, socket) do
    Memory.link(memory)
    {:noreply, assign(socket, memory: memory)}
  end

  def handle_async(:connect, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, vault_error: message)}

  def handle_async(:connect, {:exit, reason}, socket),
    do: {:noreply, assign(socket, vault_error: "connecting failed: #{inspect(reason)}")}

  def handle_async(:remember, {:ok, {:ok, entry}}, socket) do
    {:noreply,
     assign(socket,
       saved: socket.assigns.saved ++ [Memory.preference(entry)],
       remember_form: remember_form()
     )}
  end

  def handle_async(:remember, {:ok, {:error, message}}, socket),
    do: {:noreply, put_flash(socket, :error, message)}

  def handle_async(:remember, {:exit, reason}, socket),
    do: {:noreply, put_flash(socket, :error, "saving failed: #{inspect(reason)}")}

  def handle_async(:reply, {:ok, {:ok, text, context}}, socket) do
    reply = %{role: "assistant", text: text, context: context}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [reply], replying: false)}
  end

  def handle_async(:reply, {:ok, {:error, message}}, socket),
    do: {:noreply, socket |> assign(replying: false) |> put_flash(:error, message)}

  def handle_async(:reply, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(replying: false) |> put_flash(:error, "no reply: #{inspect(reason)}")}
  end

  # A page that closes cleanly disposes of its hook subject. Should the process
  # die instead, the linked connection processes die with it, and the subject is
  # left to the target (the reference evicts the oldest past a cap).
  @impl true
  def terminate(_reason, %{assigns: %{memory: %Memory{} = memory}}), do: Memory.close(memory)
  def terminate(_reason, _socket), do: :ok

  # Recalls with the latest message as the query, so only the memories it touches
  # leave the vault, then asks ChatGPT with the conversation so far.
  @spec answer(Memory.t(), map(), [OpenAI.message()], boolean()) ::
          {:ok, String.t(), :off | [map()]} | {:error, String.t()}
  defp answer(memory, openai, messages, use_memory) do
    with {:ok, context} <- recall(memory, List.last(messages).text, use_memory),
         {:ok, text} <-
           OpenAI.respond(
             instructions(context),
             Enum.map(messages, &Map.take(&1, [:role, :text])),
             key: openai["key"],
             model: openai["model"]
           ) do
      {:ok, text, context}
    end
  end

  defp recall(_memory, _query, false = _use_memory), do: {:ok, :off}
  defp recall(memory, query, true), do: Memory.recall(memory, query)

  defp instructions(:off), do: Memory.instructions([])
  defp instructions(entries), do: Memory.instructions(entries)

  defp remember_form, do: to_form(%{"text" => ""}, as: :memory)

  defp chat_form(use_memory),
    do: to_form(%{"text" => "", "use_memory" => use_memory}, as: :chat)
end
