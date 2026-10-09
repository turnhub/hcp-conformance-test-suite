defmodule HcpConformanceWeb.ChatLive do
  @moduledoc """
  Portable memory, with every grant mechanic explicit: the person's HCP vault on
  one side, assistants (ChatGPT, Claude) on the other, and nothing shared
  between them except through grants the person issues here.

  - The vault starts with no grants. The person issues each one: which
    assistant, which categories, read and/or write, temporary or persistent, and
    optionally narrowed to particular memories. The conformance hook stands in
    for the vault's consent screen.
  - Every grant shows its status, and can be revoked; the assistant's next
    request is then refused by the vault, not by this page.
  - Memories are written by the person or by an assistant through its grant,
    with their category, dimension and declaration; an inference that
    contradicts the person is quarantined (§2.6).
  - Each message is searched in the vault with the assistant's own grant, and
    the reply says what happened: no grant held, refused and why, or which
    memories were sent.
  - The audit log and every HCP call the page made (request and response,
    credentials redacted) are on the page.

  Stateless like the run page: keys live in the encrypted session cookie, the
  conversation and grant tokens in this process, and OpenAI and Anthropic are
  asked not to store anything.
  """

  use HcpConformanceWeb, :live_view

  alias HcpConformance.{Assistants, Runs, Vault}
  alias HcpConformanceWeb.Exchanges

  @max_calls 25
  @max_audit 60

  @impl true
  def mount(_params, %{"connection" => connection} = session, socket) when is_map(connection) do
    case Runs.config(connection) do
      {:ok, config} ->
        {:ok,
         socket
         |> assign(
           page_title: "Chat",
           target: connection["target"],
           keys: session["assistants"] || %{},
           vault: nil,
           vault_error: nil,
           categories: [],
           busy: false,
           grants: [],
           entries: [],
           audit: [],
           held: %{},
           calls: [],
           call_count: 0,
           messages: [],
           replying: false,
           grant_form: grant_form(),
           memory_form: memory_form(),
           chat_form: chat_form(nil, true)
         )
         |> connect_vault(config)}

      {:error, message} ->
        {:ok, socket |> put_flash(:error, message) |> redirect(to: ~p"/")}
    end
  end

  def mount(_params, _session, socket) do
    {:ok, socket |> put_flash(:info, "Connect to a target first.") |> redirect(to: ~p"/")}
  end

  defp connect_vault(socket, config) do
    if connected?(socket),
      do: start_async(socket, :connect, fn -> Vault.connect(config) end),
      else: socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Portable memory
        <:subtitle>
          The person's HCP vault, and assistants that see it only through grants issued here.
        </:subtitle>
      </.header>

      <.vault_status target={@target} vault={@vault} error={@vault_error} />

      <.keys_card keys={@keys} />
      <.grants_card
        :if={@vault}
        vault={@vault}
        form={@grant_form}
        categories={@categories}
        entries={@entries}
        grants={@grants}
        busy={@busy}
      />
      <.memories_card
        :if={@vault}
        form={@memory_form}
        categories={@categories}
        entries={@entries}
        busy={@busy}
      />
      <.chat_card
        :if={@vault && @keys != %{}}
        form={@chat_form}
        keys={@keys}
        held={@held}
        categories={@categories}
        messages={@messages}
        replying={@replying}
      />
      <.calls_card :if={@vault} calls={@calls} />
      <.audit_card :if={@vault} audit={@audit} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Download">
        export default {
          mounted() {
            this.handleEvent("download", ({filename, content}) => {
              const url = URL.createObjectURL(new Blob([content], {type: "application/json"}))
              const link = document.createElement("a")
              link.href = url
              link.download = filename
              link.click()
              URL.revokeObjectURL(url)
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :target, :string, required: true
  attr :vault, :any, required: true
  attr :error, :string, required: true

  defp vault_status(assigns) do
    ~H"""
    <div id="vault">
      <div :if={@error} role="alert" class="alert alert-error">{@error}</div>
      <div :if={!@error and !@vault} class="alert">
        <span class="loading loading-spinner"></span> Connecting to the vault…
      </div>
      <div :if={@vault} class="alert alert-success">
        <span>
          Connected as the person to <span class="break-all">{@target}</span>. Assistants
          see nothing until you grant them access.
        </span>
      </div>
    </div>
    """
  end

  attr :vault, :any, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :categories, :list, required: true
  attr :entries, :list, required: true
  attr :grants, :list, required: true
  attr :busy, :boolean, required: true

  defp grants_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">Grants</h2>
        <p>
          A grant is the person's consent: which assistant, which categories, read or write, and
          for how long. The vault enforces it on every request. Here the conformance hook stands
          in for the vault's consent screen.
        </p>

        <div :if={!Vault.can_issue?(@vault)} role="alert" class="alert alert-warning">
          Issuing grants needs the conformance hook. Connect with one to demonstrate them.
        </div>

        <.form
          :if={Vault.can_issue?(@vault)}
          for={@form}
          id="grant-form"
          phx-submit="issue_grant"
          class="space-y-2"
        >
          <.input
            field={@form[:assistant]}
            type="select"
            label="Grant to"
            options={Enum.map(Assistants.all(), &{&1.name, &1.id})}
          />
          <fieldset class="fieldset">
            <legend class="fieldset-legend">Categories</legend>
            <label :for={category <- @categories} class="label">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                name="grant[categories][]"
                value={category}
                checked={category in (@form.params["categories"] || [])}
              />
              {category}
            </label>
          </fieldset>
          <fieldset class="fieldset">
            <legend class="fieldset-legend">Access</legend>
            <.input field={@form[:read]} type="checkbox" label="Read" />
            <.input field={@form[:write]} type="checkbox" label="Write" />
          </fieldset>
          <.input
            field={@form[:grant_type]}
            type="select"
            label="Type"
            options={[{"Temporary", "temporary"}, {"Persistent", "persistent"}]}
          />
          <.input
            field={@form[:expires_in]}
            type="number"
            label="Expires after (seconds, temporary grants)"
            min="1"
            max="86400"
          />
          <fieldset :if={@entries != []} class="fieldset">
            <legend class="fieldset-legend">Narrow reads to these memories (optional)</legend>
            <label :for={entry <- @entries} class="label">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                name="grant[restrict_to][]"
                value={entry["id"]}
              />
              {Vault.preference(entry)}
            </label>
          </fieldset>
          <.button variant="primary" disabled={@busy}>Issue grant</.button>
        </.form>

        <div id="grants" class="overflow-x-auto">
          <p :if={@grants == []}>
            No grants yet. Assistants see nothing until you grant them access.
          </p>
          <table :if={@grants != []} class="table table-sm">
            <thead>
              <tr>
                <th>Assistant</th>
                <th>Scopes</th>
                <th>Type</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={grant <- @grants}>
                <td>
                  {get_in(grant, ["client", "name"])}
                  <div><code>{short(grant["grantId"])}</code></div>
                </td>
                <td>
                  <span :for={scope <- grant["scopes"] || []} class="badge badge-ghost badge-sm">
                    {scope}
                  </span>
                  <div :if={restricted(grant) > 0}>
                    narrowed to {restricted(grant)} {plural(restricted(grant), "memory", "memories")}
                  </div>
                </td>
                <td>
                  {grant["grantType"]}
                  <div :if={grant["expiresAt"]}>until {time(grant["expiresAt"])}</div>
                </td>
                <td>
                  <span class={["badge", grant_status_class(grant_status(grant))]}>
                    {grant_status(grant)}
                  </span>
                </td>
                <td>
                  <.button
                    :if={grant_status(grant) == "active"}
                    phx-click="revoke"
                    phx-value-grant={grant["grantId"]}
                    disabled={@busy}
                  >
                    Revoke
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :categories, :list, required: true
  attr :entries, :list, required: true
  attr :busy, :boolean, required: true

  defp memories_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">Memories</h2>
        <p>
          The person's memories, whoever wrote them. An assistant writes only with a grant that
          includes write; an inference that contradicts something the person declared, on the
          same dimension, is quarantined as conflicted.
        </p>

        <.form for={@form} id="memory-form" phx-submit="remember" class="space-y-2">
          <.input
            field={@form[:text]}
            label="Memory"
            placeholder="I need high arch support in my running shoes."
          />
          <.input field={@form[:category]} type="select" label="Category" options={@categories} />
          <.input field={@form[:dimension]} label="Dimension (optional)" placeholder="diet" />
          <.input
            field={@form[:author]}
            type="select"
            label="Written by"
            options={[
              {"The person", "person"}
              | Enum.map(Assistants.all(), &{"#{&1.name}, through its grant", &1.id})
            ]}
          />
          <.input
            field={@form[:declaration_type]}
            type="select"
            label="Declared as"
            options={[
              {"user-declared: the person said it", "user-declared"},
              {"model-inferred: an assistant inferred it", "model-inferred"},
              {"issuer-attested: a third party attests it", "issuer-attested"}
            ]}
          />
          <.input
            field={@form[:confidence]}
            type="select"
            label="Confidence (model-inferred only)"
            options={[{"none", ""}, {"high", "high"}, {"medium", "medium"}, {"low", "low"}]}
          />
          <.button variant="primary" disabled={@busy}>Save to the vault</.button>
        </.form>

        <ul id="entries" class="list">
          <li :for={entry <- @entries} class="list-row" data-entry={entry["id"]}>
            <div>
              <div>{Vault.preference(entry)}</div>
              <span class="badge badge-ghost badge-sm">{Vault.category(entry)}</span>
              <span :if={Vault.dimension(entry)} class="badge badge-ghost badge-sm">
                {Vault.dimension(entry)}
              </span>
              <span class="badge badge-ghost badge-sm">{Vault.declaration(entry)}</span>
              <span :if={Vault.confidence(entry)} class="badge badge-ghost badge-sm">
                {Vault.confidence(entry)}
              </span>
              <span class={["badge badge-sm", entry_status_class(Vault.status(entry))]}>
                {Vault.status(entry)}
              </span>
            </div>
          </li>
        </ul>

        <div class="card-actions">
          <.button id="export" phx-click="export" phx-hook=".Download" disabled={@busy}>
            <.icon name="hero-arrow-down-tray" /> Export the vault (JSON)
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :audit, :list, required: true

  defp audit_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">Audit log</h2>
        <p>
          What the vault recorded, newest first: every grant, read and write, and who made it.
          The person's own exports from this page show too.
        </p>
        <div id="audit" class="overflow-x-auto">
          <p :if={@audit == []}>Nothing recorded yet.</p>
          <table :if={@audit != []} class="table table-sm">
            <thead>
              <tr>
                <th>Time</th>
                <th>Event</th>
                <th>By</th>
                <th>Details</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={event <- @audit}>
                <td>{time(event["timestamp"])}</td>
                <td><code>{event["eventType"]}</code></td>
                <td>{actor(event)}</td>
                <td class="break-all">{event_details(event)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :keys, :map, required: true

  defp keys_card(assigns) do
    ~H"""
    <div id="keys" class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">Assistants</h2>
        <p>
          Each assistant is a separate HCP client with grants of its own. Its API key stays in
          your encrypted session cookie, and requests ask its vendor not to store anything.
        </p>
        <div :for={assistant <- Assistants.all()}>
          <div :if={@keys[assistant.id]} class="flex flex-wrap items-center gap-2">
            <span class="badge badge-success">{assistant.name}</span>
            <span>key set, model <code>{@keys[assistant.id]["model"]}</code></span>
            <.link href={~p"/chat/keys/#{assistant.id}"} method="delete" class="link">
              Forget
            </.link>
          </div>
          <.form
            :if={!@keys[assistant.id]}
            for={
              to_form(%{"assistant" => assistant.id, "key" => "", "model" => assistant.default_model},
                as: :key
              )
            }
            id={"key-form-#{assistant.id}"}
            action={~p"/chat/keys"}
          >
            <input type="hidden" name="key[assistant]" value={assistant.id} />
            <.input
              name="key[key]"
              value=""
              type="password"
              label={"#{assistant.vendor} API key, for #{assistant.name}"}
              autocomplete="off"
            />
            <.input name="key[model]" value={assistant.default_model} label="Model" />
            <.button>Use this key</.button>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :keys, :map, required: true
  attr :held, :map, required: true
  attr :categories, :list, required: true
  attr :messages, :list, required: true
  attr :replying, :boolean, required: true

  defp chat_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">Chat</h2>
        <p>
          Each message is searched in the vault with the chosen assistant's own grant; only what
          the vault returns is passed on, and the reply says exactly what happened.
        </p>
        <ul class="list">
          <li :for={assistant <- Assistants.all()} :if={@keys[assistant.id]} class="list-row">
            <div>
              {assistant.name}: <span :if={!@held[assistant.id]}>holds no grant</span>
              <span :if={@held[assistant.id]}>
                holds grant <code>{short(@held[assistant.id].grant_id)}</code>
                <span :for={scope <- @held[assistant.id].scopes} class="badge badge-ghost badge-sm">
                  {scope}
                </span>
              </span>
            </div>
          </li>
        </ul>

        <div id="messages">
          <.message :for={message <- @messages} message={message} />
          <div :if={@replying} class="chat chat-start">
            <div class="chat-bubble"><span class="loading loading-dots"></span></div>
          </div>
        </div>

        <.form for={@form} id="chat-form" phx-submit="send" class="space-y-2">
          <.input
            field={@form[:assistant]}
            type="select"
            label="Ask"
            options={for a <- Assistants.all(), @keys[a.id], do: {a.name, a.id}}
          />
          <.input field={@form[:text]} type="textarea" label="Message" />
          <.input
            field={@form[:use_vault]}
            type="checkbox"
            label="Search the vault with the assistant's grant"
          />
          <details class="collapse collapse-arrow bg-base-100">
            <summary class="collapse-title">Search settings</summary>
            <div class="collapse-content space-y-2">
              <.input
                field={@form[:pick_words]}
                type="checkbox"
                label="Let the assistant pick the search words (otherwise the message itself is searched)"
              />
              <.input
                field={@form[:query]}
                label="Or search for these words instead"
                placeholder="running shoes"
              />
              <fieldset class="fieldset">
                <legend class="fieldset-legend">
                  Search beyond the grant: tick categories to send instead of the ones the grant
                  can read (the vault refuses any it does not cover)
                </legend>
                <label :for={category <- @categories} class="label">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    name="chat[categories][]"
                    value={category}
                  />
                  {category}
                </label>
              </fieldset>
              <.input
                field={@form[:max_entries]}
                type="number"
                label="Most memories to return"
                min="1"
                max="20"
              />
              <.input
                field={@form[:detail]}
                type="select"
                label="Response detail"
                options={[{"full", "full"}, {"minimal: provenance redacted", "minimal"}]}
              />
              <.input field={@form[:purpose]} label="Purpose (recorded in the audit log)" />
            </div>
          </details>
          <.button variant="primary" disabled={@replying}>Send</.button>
        </.form>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true

  defp message(%{message: %{role: "user"}} = assigns) do
    ~H"""
    <div class="chat chat-end">
      <div class="chat-header">to {@message.to}</div>
      <div class="chat-bubble chat-bubble-primary">{@message.text}</div>
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div class="chat chat-start">
      <div class="chat-header">{@message.name}</div>
      <div class={["chat-bubble", @message[:error] && "chat-bubble-error"]}>{@message.text}</div>
      <div class="chat-footer" data-role="context">
        <.context name={@message.name} context={@message.context} />
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :context, :any, required: true

  defp context(%{context: :off} = assigns),
    do: ~H"Vault off: nothing was asked of the vault."

  defp context(%{context: :no_grant} = assigns),
    do: ~H"{@name} holds no grant: nothing was asked of the vault."

  defp context(%{context: {:refused, refusal, search}} = assigns) do
    assigns = assign(assigns, refusal: refusal, search: search)

    ~H"""
    <.searched name={@name} search={@search} />
    The vault refused {@name}: {@refusal.status} {@refusal.type}: {@refusal.detail}.
    It answered without memories.
    """
  end

  defp context(%{context: {:ok, [], search}} = assigns) do
    assigns = assign(assigns, search: search)

    ~H"""
    <.searched name={@name} search={@search} />
    <span :if={@search.method == "lexical"}>
      The vault's search is lexical, and no memory shares a word with the query, so none was sent.
    </span>
    <span :if={@search.method != "lexical"}>No memory matched, so none was sent.</span>
    """
  end

  defp context(%{context: {:ok, entries, search}} = assigns) do
    assigns = assign(assigns, entries: entries, search: search)

    ~H"""
    <.searched name={@name} search={@search} />
    <details class="collapse collapse-arrow bg-base-100">
      <summary class="collapse-title">
        Sent from the vault: {length(@entries)} {plural(length(@entries), "memory", "memories")}
      </summary>
      <ul class="collapse-content list">
        <li :for={entry <- @entries} class="list-row">
          <div>
            {Vault.preference(entry)} <span class="badge badge-sm">{Vault.category(entry)}</span>
          </div>
        </li>
      </ul>
    </details>
    """
  end

  attr :name, :string, required: true
  attr :search, :map, required: true

  defp searched(%{search: %{chosen_by: :assistant}} = assigns) do
    ~H"""
    {@name} picked the search words “{@search.query}” and searched {Enum.join(
      @search.categories,
      ", "
    )}.
    """
  end

  defp searched(%{search: %{chosen_by: :person}} = assigns) do
    ~H"""
    {@name} searched {Enum.join(@search.categories, ", ")} for “{@search.query}”, the words you set.
    """
  end

  defp searched(%{search: %{pick_error: _error}} = assigns) do
    ~H"""
    {@name} could not pick search words ({@search.pick_error}), so it searched {Enum.join(
      @search.categories,
      ", "
    )} for “{@search.query}”, the message itself.
    """
  end

  defp searched(assigns) do
    ~H"""
    {@name} searched {Enum.join(@search.categories, ", ")} for “{@search.query}”, the message itself.
    """
  end

  attr :calls, :list, required: true

  defp calls_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">HCP calls</h2>
        <p>
          Every request this page made to the vault, newest first, with the response. Bearer
          tokens and the hook secret are redacted.
        </p>
        <div id="calls" class="space-y-2">
          <p :if={@calls == []}>None yet.</p>
          <details
            :for={call <- @calls}
            id={"call-#{call.id}"}
            class="collapse collapse-arrow bg-base-100"
          >
            <summary class="collapse-title">
              <span class={["badge", if(call.ok, do: "badge-success", else: "badge-error")]}>
                {if call.ok, do: "done", else: "refused"}
              </span>
              {call.label}
              <span class="badge badge-ghost">{plural(
                length(call.exchanges),
                "request",
                "requests",
                true
              )}</span>
            </summary>
            <div class="collapse-content space-y-2">
              <Exchanges.exchange
                :for={exchange <- call.exchanges}
                row={"call-#{call.id}"}
                exchange={exchange}
              />
            </div>
          </details>
        </div>
      </div>
    </div>
    """
  end

  # Events -------------------------------------------------------------------------------

  @impl true
  def handle_event("issue_grant", %{"grant" => params}, socket) do
    case grant_request(params) do
      {:ok, assistant, attrs} ->
        vault = socket.assigns.vault

        {:noreply,
         socket
         |> assign(grant_form: to_form(params, as: :grant))
         |> vault_op(
           {:grant, assistant.id},
           "Grant #{assistant.name} access",
           [:grants, :audit],
           fn ->
             Vault.issue_grant(vault, assistant, attrs)
           end
         )}

      :incomplete ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Choose an assistant, at least one category, and read or write."
         )}
    end
  end

  def handle_event("revoke", %{"grant" => grant_id}, socket) do
    vault = socket.assigns.vault

    {:noreply,
     vault_op(socket, :revoke, "Revoke grant #{short(grant_id)}", [:grants, :audit], fn ->
       Vault.revoke(vault, grant_id)
     end)}
  end

  def handle_event("remember", %{"memory" => params}, socket) do
    with {:ok, text} <- present(params["text"], "Write the memory first."),
         {:ok, author, who} <- author(socket.assigns, params["author"]) do
      attrs = %{
        text: text,
        category: params["category"],
        dimension: params["dimension"],
        declaration_type: params["declaration_type"],
        confidence: params["confidence"]
      }

      vault = socket.assigns.vault

      {:noreply,
       socket
       |> assign(memory_form: memory_form(Map.put(params, "text", "")))
       |> vault_op(:remember, "#{who} saved a memory", [:entries, :audit], fn ->
         Vault.remember(vault, author, attrs)
       end)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("export", _params, socket) do
    vault = socket.assigns.vault

    {:noreply,
     vault_op(socket, :export, "The person exported the vault", [:audit], fn ->
       Vault.export(vault)
     end)}
  end

  def handle_event("send", %{"chat" => params}, socket) do
    with {:ok, text} <- present(params["text"], "Write a message first."),
         %{} = assistant <- Assistants.get(params["assistant"] || ""),
         %{} = key <- socket.assigns.keys[assistant.id] do
      use_vault = params["use_vault"] == "true"
      message = %{role: "user", text: text, to: assistant.name}
      messages = socket.assigns.messages ++ [message]
      %{vault: vault, held: held} = socket.assigns
      search = search_opts(params)

      {:noreply,
       socket
       |> assign(messages: messages, replying: true, chat_form: chat_form(params, use_vault))
       |> start_async(:reply, fn ->
         answer(vault, assistant, key, held[assistant.id], history(messages), use_vault, search)
       end)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      _no_assistant -> {:noreply, put_flash(socket, :error, "Choose an assistant with a key.")}
    end
  end

  # Async results ------------------------------------------------------------------------

  @impl true
  def handle_async(:connect, {:ok, {:ok, vault}}, socket) do
    Vault.link(vault)
    {:noreply, assign(socket, vault: vault, categories: Vault.categories(vault))}
  end

  def handle_async(:connect, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, vault_error: message)}

  def handle_async(:connect, {:exit, reason}, socket),
    do: {:noreply, assign(socket, vault_error: "connecting failed: #{inspect(reason)}")}

  def handle_async(:vault, {:ok, {kind, label, result, exchanges, fresh}}, socket) do
    {:noreply,
     socket
     |> assign(fresh)
     |> assign(busy: false)
     |> log_call(label, result, exchanges)
     |> after_op(kind, result)}
  end

  def handle_async(:vault, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(busy: false)
     |> put_flash(:error, "the vault call failed: #{inspect(reason)}")}
  end

  def handle_async(:reply, {:ok, {reply, name, context, call, fresh}}, socket) do
    socket =
      case call do
        {label, result, exchanges} -> log_call(socket, label, result, exchanges)
        nil -> socket
      end

    message =
      case reply do
        {:ok, text} ->
          %{role: "assistant", name: name, text: text, context: context}

        {:error, error} ->
          %{role: "assistant", name: name, text: error, context: context, error: true}
      end

    {:noreply,
     socket
     |> assign(fresh)
     |> assign(messages: socket.assigns.messages ++ [message], replying: false)}
  end

  def handle_async(:reply, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(replying: false) |> put_flash(:error, "no reply: #{inspect(reason)}")}
  end

  # A page that closes cleanly disposes of its hook subject. Should the process
  # die instead, the linked connection processes die with it, and the subject is
  # left to the target (the reference evicts the oldest past a cap).
  @impl true
  def terminate(_reason, %{assigns: %{vault: %Vault{} = vault}}), do: Vault.close(vault)
  def terminate(_reason, _socket), do: :ok

  # Operations ---------------------------------------------------------------------------

  # Runs a vault operation as an async task: its result, the HTTP exchanges it
  # made, and the panels it changes, read again afterwards.
  defp vault_op(socket, kind, label, refresh, operation) do
    vault = socket.assigns.vault

    socket
    |> assign(busy: true)
    |> start_async(:vault, fn ->
      {result, exchanges} = Vault.traced(vault, operation)
      {kind, label, result, exchanges, refreshed(vault, refresh)}
    end)
  end

  defp refreshed(vault, panels) do
    for panel <- panels, {:ok, value} <- [read(vault, panel)], into: %{}, do: {panel, value}
  end

  defp read(vault, :grants), do: Vault.grants(vault)
  defp read(vault, :entries), do: Vault.entries(vault)

  defp read(vault, :audit) do
    with {:ok, events} <- Vault.audit(vault), do: {:ok, Enum.take(events, @max_audit)}
  end

  defp after_op(socket, {:grant, assistant_id}, {:ok, grant}),
    do: update(socket, :held, &Map.put(&1, assistant_id, grant))

  defp after_op(socket, :export, {:ok, json}),
    do: push_event(socket, "download", %{filename: "hcp-vault-export.json", content: json})

  defp after_op(socket, _kind, {:error, error}), do: put_flash(socket, :error, describe(error))
  defp after_op(socket, _kind, _result), do: socket

  defp log_call(socket, label, result, exchanges) do
    id = socket.assigns.call_count + 1

    call = %{
      id: id,
      label: label,
      ok: ok?(result),
      exchanges: Enum.map(exchanges, &Exchanges.entry/1)
    }

    assign(socket, call_count: id, calls: Enum.take([call | socket.assigns.calls], @max_calls))
  end

  # Searches the vault with the assistant's own grant (unless the vault is off or
  # it holds none), then asks the assistant with only what came back.
  @spec answer(
          Vault.t(),
          Assistants.t(),
          map(),
          map() | nil,
          [Assistants.message()],
          boolean(),
          keyword()
        ) ::
          {{:ok, String.t()} | {:error, String.t()}, String.t(), term(), tuple() | nil, map()}
  defp answer(vault, assistant, key, grant, messages, use_vault, search) do
    {context, call} = recall(vault, {assistant, key}, grant, messages, use_vault, search)
    entries = sent(context)

    reply =
      Assistants.respond(assistant, Vault.instructions(assistant.name, entries), messages,
        key: key["key"],
        model: key["model"]
      )

    fresh = if call, do: refreshed(vault, [:grants, :audit]), else: %{}
    {reply, assistant.name, context, call, fresh}
  end

  defp sent({:ok, entries, _searched}), do: entries
  defp sent(_context), do: []

  defp recall(_vault, _assistant, _grant, _messages, false = _use_vault, _search), do: {:off, nil}
  defp recall(_vault, _assistant, nil = _grant, _messages, true, _search), do: {:no_grant, nil}

  defp recall(vault, {assistant, _key} = asker, grant, messages, true, search) do
    categories = search[:categories] || Vault.readable(grant)
    method = Vault.minimization(vault)

    searched =
      Map.merge(
        %{categories: categories, method: method},
        query(asker, messages, search, categories, method)
      )

    {result, exchanges} =
      Vault.traced(vault, fn ->
        Vault.recall(vault, grant, searched.query, Keyword.put(search, :categories, categories))
      end)

    context =
      case result do
        {:ok, entries} -> {:ok, entries, searched}
        {:error, refusal} -> {:refused, refusal, searched}
      end

    {context, {"#{assistant.name} searched the vault", result, exchanges}}
  end

  # What the vault is searched for: the words the person set, else the words the
  # assistant picks, else (or when picking fails) the message itself.
  defp query({assistant, key}, messages, search, categories, method) do
    message = List.last(messages).text

    cond do
      search[:query] ->
        %{query: search[:query], chosen_by: :person}

      search[:pick_words] ->
        opts = [key: key["key"], model: key["model"]]

        case Assistants.pick_words(
               assistant,
               messages,
               %{categories: categories, method: method},
               opts
             ) do
          {:ok, words} -> %{query: words, chosen_by: :assistant}
          {:error, error} -> %{query: message, chosen_by: :message, pick_error: error}
        end

      true ->
        %{query: message, chosen_by: :message}
    end
  end

  # Helpers --------------------------------------------------------------------------------

  defp history(messages) do
    for %{role: role, text: text} = message <- messages,
        !message[:error],
        do: %{role: role, text: text}
  end

  defp search_opts(params) do
    [
      query: non_empty(String.trim(params["query"] || "")),
      pick_words: params["pick_words"] != "false",
      categories: non_empty(params["categories"]),
      max_entries: integer(params["max_entries"], 5),
      detail: params["detail"],
      purpose: non_empty(params["purpose"])
    ]
  end

  defp grant_request(params) do
    actions = for action <- ["read", "write"], params[action] == "true", do: action

    case {Assistants.get(params["assistant"] || ""), params["categories"] || [], actions} do
      {%{} = assistant, [_ | _] = categories, [_ | _]} ->
        {:ok, assistant,
         %{
           categories: categories,
           actions: actions,
           grant_type: params["grant_type"],
           expires_in: integer(params["expires_in"], 600),
           restrict_to: Enum.reject(params["restrict_to"] || [], &(&1 == ""))
         }}

      _incomplete ->
        :incomplete
    end
  end

  defp author(_assigns, "person"), do: {:ok, :person, "The person"}

  defp author(%{held: held}, id) do
    case {Assistants.get(id || ""), held[id]} do
      {nil, _grant} ->
        {:error, "Choose who writes the memory."}

      {assistant, nil} ->
        {:error, "#{assistant.name} holds no grant to write with. Grant it write first."}

      {assistant, grant} ->
        {:ok, grant.token, assistant.name}
    end
  end

  defp present(value, message) do
    case String.trim(value || "") do
      "" -> {:error, message}
      text -> {:ok, text}
    end
  end

  defp non_empty(value) when value in [nil, "", []], do: nil
  defp non_empty(value), do: value

  defp integer(value, default) do
    case Integer.parse(to_string(value || "")) do
      {number, ""} when number > 0 -> number
      _other -> default
    end
  end

  defp ok?(:ok), do: true
  defp ok?({:ok, _value}), do: true
  defp ok?(_error), do: false

  defp describe(%{status: status, type: type, detail: detail}), do: "#{status} #{type}: #{detail}"
  defp describe(message) when is_binary(message), do: message

  defp grant_form do
    to_form(
      %{
        "assistant" => "chatgpt",
        "categories" => [],
        "read" => "true",
        "write" => "false",
        "grant_type" => "temporary",
        "expires_in" => "600"
      },
      as: :grant
    )
  end

  defp memory_form(params \\ %{}) do
    defaults = %{
      "text" => "",
      "category" => "general_preferences",
      "dimension" => "",
      "author" => "person",
      "declaration_type" => "user-declared",
      "confidence" => ""
    }

    to_form(Map.merge(defaults, params), as: :memory)
  end

  defp chat_form(params, use_vault) do
    defaults = %{
      "assistant" => nil,
      "pick_words" => true,
      "max_entries" => "5",
      "detail" => "full",
      "purpose" => ""
    }

    kept =
      Map.take(params || %{}, ["assistant", "pick_words", "max_entries", "detail", "purpose"])

    to_form(defaults |> Map.merge(kept) |> Map.merge(%{"text" => "", "use_vault" => use_vault}),
      as: :chat
    )
  end

  # A grant is expired once its expiry has passed, before the vault marks it so on
  # its next use.
  defp grant_status(%{"status" => "active", "expiresAt" => expires_at})
       when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, time, _offset} ->
        if DateTime.before?(time, DateTime.utc_now()), do: "expired", else: "active"

      _invalid ->
        "active"
    end
  end

  defp grant_status(grant), do: grant["status"]

  defp grant_status_class("active"), do: "badge-success"
  defp grant_status_class("revoked"), do: "badge-error"
  defp grant_status_class(_status), do: "badge-warning"

  defp entry_status_class("active"), do: "badge-success"
  defp entry_status_class("conflicted"), do: "badge-warning"
  defp entry_status_class(_status), do: "badge-ghost"

  defp restricted(grant) do
    grant
    |> Map.get("restrictions", [])
    |> Enum.flat_map(&(get_in(&1, ["narrowedTo", "entryIds"]) || []))
    |> Enum.uniq()
    |> length()
  end

  defp actor(%{"actorType" => "user"}), do: "the person"
  defp actor(%{"actorType" => "system"}), do: "the vault"

  defp actor(%{"actorId" => id}) when is_binary(id) do
    case Enum.find(Assistants.all(), &String.starts_with?(id, &1.id <> "-")) do
      nil -> id
      assistant -> assistant.name
    end
  end

  defp actor(_event), do: ""

  defp event_details(event) do
    [
      event["category"] && "category #{event["category"]}",
      event["purpose"] && "purpose: #{event["purpose"]}",
      event["grantId"] && "grant #{short(event["grantId"])}",
      event["entryId"] && "entry #{short(event["entryId"])}",
      event["detail"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp short("urn:uuid:" <> uuid), do: String.slice(uuid, 0, 8)
  defp short(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short(_id), do: ""

  defp time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, time, _offset} -> Calendar.strftime(time, "%H:%M:%S")
      _invalid -> iso
    end
  end

  defp time(_iso), do: ""

  defp plural(count, one, many, with_count \\ false)
  defp plural(1, one, _many, with_count), do: if(with_count, do: "1 #{one}", else: one)

  defp plural(count, _one, many, with_count),
    do: if(with_count, do: "#{count} #{many}", else: many)
end
