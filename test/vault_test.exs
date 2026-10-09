defmodule HcpConformance.VaultTest do
  # The person's side of the chat page against a reference implementation: no
  # grant until the person issues one, and every grant mechanic explicit.
  use ExUnit.Case, async: true

  alias HcpConformance.{Config, ReferenceTarget, Vault}

  @chatgpt %{id: "chatgpt", name: "ChatGPT"}
  @claude %{id: "claude", name: "Claude"}

  setup do
    target = ReferenceTarget.start!()
    {:ok, config} = Config.new(ReferenceTarget.hook_config(target))
    {:ok, vault} = Vault.connect(config)
    %{vault: vault, target: target}
  end

  defp grant!(vault, assistant, attrs) do
    {:ok, grant} = Vault.issue_grant(vault, assistant, attrs)
    grant
  end

  defp remember!(vault, author, attrs) do
    {:ok, entry} = Vault.remember(vault, author, attrs)
    entry
  end

  defp texts(entries), do: Enum.map(entries, &Vault.preference/1)

  test "connecting issues no grant: assistants get access only when the person grants it", %{
    vault: vault
  } do
    assert {:ok, []} = Vault.grants(vault)
    assert length(Vault.categories(vault)) == 9
    assert Vault.can_issue?(vault)
  end

  test "a grant names the assistant, its scopes, its type and its expiry", %{vault: vault} do
    grant =
      grant!(vault, @chatgpt, %{
        categories: ["general_preferences", "health_context"],
        actions: ["read"],
        grant_type: "temporary",
        expires_in: 600
      })

    assert grant.scopes == ["hcp:general_preferences:read", "hcp:health_context:read"]

    assert {:ok,
            [
              %{
                "grantId" => grant_id,
                "client" => %{"name" => "ChatGPT"},
                "grantType" => "temporary",
                "status" => "active",
                "expiresAt" => expires_at
              }
            ]} = Vault.grants(vault)

    assert grant_id == grant.grant_id
    assert is_binary(expires_at)

    persistent =
      grant!(vault, @claude, %{
        categories: ["work_context"],
        actions: ["read", "write"],
        grant_type: "persistent"
      })

    assert persistent.expires_at == nil
  end

  test "an assistant recalls only within its grant; outside it the vault refuses", %{vault: vault} do
    remember!(vault, :person, %{text: "I am allergic to penicillin.", category: "health_context"})

    grant =
      grant!(vault, @chatgpt, %{
        categories: ["health_context"],
        actions: ["read"],
        grant_type: "persistent"
      })

    assert {:ok, [entry]} =
             Vault.recall(vault, grant, "Am I allergic to anything?",
               categories: ["health_context"]
             )

    assert Vault.preference(entry) == "I am allergic to penicillin."

    assert {:error, %{status: 403, type: "scope-denied"}} =
             Vault.recall(vault, grant, "anything", categories: ["work_context"])
  end

  test "a grant narrowed to memories reads only those", %{vault: vault} do
    kept = remember!(vault, :person, %{text: "I run marathons.", category: "general_preferences"})
    remember!(vault, :person, %{text: "I run a bakery.", category: "general_preferences"})

    grant =
      grant!(vault, @chatgpt, %{
        categories: ["general_preferences"],
        actions: ["read"],
        grant_type: "persistent",
        restrict_to: [kept["id"]]
      })

    assert {:ok, [%{"restrictions" => [%{"narrowedTo" => %{"entryIds" => [_id]}}]}]} =
             Vault.grants(vault)

    assert {:ok, entries} = Vault.recall(vault, grant, "What do I run?")
    assert texts(entries) == ["I run marathons."]
  end

  test "revoking a grant cuts the assistant off at its next request", %{vault: vault} do
    remember!(vault, :person, %{text: "I prefer window seats.", category: "general_preferences"})

    grant =
      grant!(vault, @chatgpt, %{
        categories: ["general_preferences"],
        actions: ["read"],
        grant_type: "persistent"
      })

    assert {:ok, [_entry]} = Vault.recall(vault, grant, "window seats")

    assert :ok = Vault.revoke(vault, grant.grant_id)

    assert {:ok, [%{"status" => "revoked"}]} = Vault.grants(vault)

    assert {:error, %{status: 401, type: "invalid-token"}} =
             Vault.recall(vault, grant, "window seats")
  end

  test "an assistant's inference that contradicts the person is quarantined, not recalled", %{
    vault: vault
  } do
    remember!(vault, :person, %{
      text: "I am vegetarian.",
      category: "general_preferences",
      dimension: "diet"
    })

    grant =
      grant!(vault, @claude, %{
        categories: ["general_preferences"],
        actions: ["read", "write"],
        grant_type: "persistent"
      })

    inferred =
      remember!(vault, grant.token, %{
        text: "Loves steak.",
        category: "general_preferences",
        dimension: "diet",
        declaration_type: "model-inferred",
        confidence: "medium"
      })

    assert Vault.status(inferred) == "conflicted"
    assert {:ok, entries} = Vault.entries(vault)

    assert Enum.map(entries, &{Vault.preference(&1), Vault.status(&1)}) ==
             [{"I am vegetarian.", "active"}, {"Loves steak.", "conflicted"}]

    assert {:ok, recalled} = Vault.recall(vault, grant, "vegetarian steak diet")
    assert texts(recalled) == ["I am vegetarian."]
  end

  test "the audit log shows each grant, read and revocation, newest first", %{vault: vault} do
    remember!(vault, :person, %{text: "I prefer window seats.", category: "general_preferences"})

    grant =
      grant!(vault, @chatgpt, %{
        categories: ["general_preferences"],
        actions: ["read"],
        grant_type: "persistent"
      })

    {:ok, _entries} = Vault.recall(vault, grant, "window seats", purpose: "Book a flight")
    :ok = Vault.revoke(vault, grant.grant_id)

    assert {:ok, [revoked, read, issued | _older]} = Vault.audit(vault)
    assert %{"eventType" => "grant.revoked"} = revoked
    assert %{"eventType" => "preference.read", "purpose" => "Book a flight"} = read
    assert %{"eventType" => "grant.issued"} = issued
  end

  test "export hands the person the whole vault as JSON", %{vault: vault} do
    remember!(vault, :person, %{text: "I prefer window seats.", category: "general_preferences"})

    assert {:ok, json} = Vault.export(vault)
    assert %{"entries" => [%{"id" => _id}]} = Jason.decode!(json)
  end

  test "traced returns an operation's result with the HTTP exchanges it made, redacted", %{
    vault: vault
  } do
    {{:ok, grant}, [exchange]} =
      Vault.traced(vault, fn ->
        Vault.issue_grant(vault, @chatgpt, %{
          categories: ["general_preferences"],
          actions: ["read"],
          grant_type: "persistent"
        })
      end)

    assert %{method: "POST", status: 201, kind: :hook} = exchange
    assert exchange.url =~ "/conformance-hook/subjects/"
    refute exchange.response_body =~ grant.token
  end

  test "a trace holds only its own exchanges, even when another runs inside it", %{vault: vault} do
    test = self()

    outer =
      Task.async(fn ->
        Vault.traced(vault, fn ->
          send(test, :outer_started)
          receive do: (:go -> :ok)
          Vault.remember(vault, :person, %{text: "outer", category: "general_preferences"})
        end)
      end)

    assert_receive :outer_started

    {{:ok, _inner}, [inner_exchange]} =
      Vault.traced(vault, fn ->
        Vault.remember(vault, :person, %{text: "inner", category: "general_preferences"})
      end)

    send(outer.pid, :go)

    assert {{:ok, _outer}, [outer_exchange]} = Task.await(outer)
    assert inner_exchange.response_body =~ "inner"
    assert outer_exchange.response_body =~ "outer"
  end
end
