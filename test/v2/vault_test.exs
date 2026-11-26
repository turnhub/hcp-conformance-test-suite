defmodule HcpConformance.V2.VaultTest do
  # The chat page's vault client against the v2 reference implementation: the
  # person is a Management Client, an assistant a Context Client that receives
  # disclosures under its own grant.
  use ExUnit.Case, async: true

  alias HcpConformance.{Config, ReferenceTarget, Vault}

  @chatgpt %{id: "chatgpt", name: "ChatGPT"}
  @claude %{id: "claude", name: "Claude"}
  @persistent %{categories: ["general_preferences"], actions: ["read"], grant_type: "persistent"}

  setup do
    target = ReferenceTarget.start!(version: "2.0")
    {:ok, config} = Config.new(ReferenceTarget.hook_config(target))
    {:ok, vault} = Vault.connect(config)
    %{vault: vault}
  end

  defp grant!(vault, assistant, attrs \\ %{}) do
    {:ok, grant} = Vault.issue_grant(vault, assistant, Map.merge(@persistent, attrs))
    grant
  end

  defp remember!(vault, author, text, attrs \\ %{}) do
    attrs = Map.merge(%{text: text, category: "general_preferences"}, attrs)
    {:ok, entry} = Vault.remember(vault, author, attrs)
    entry
  end

  defp stored(vault, text) do
    {:ok, entries} = Vault.entries(vault)
    Enum.find(entries, &(Vault.preference(&1) == text))
  end

  test "connecting reads the version from the vault and issues no grant", %{vault: vault} do
    assert Vault.version(vault) == "2.0"
    assert {:ok, []} = Vault.grants(vault)
    assert "general_preferences" in Vault.categories(vault)
    assert length(Vault.categories(vault)) == 9
    assert Vault.can_issue?(vault)
  end

  test "a grant names the assistant, what it may do, and the purpose the person approved", %{
    vault: vault
  } do
    grant =
      grant!(vault, @chatgpt, %{
        categories: ["general_preferences", "health_context"],
        grant_type: "temporary",
        expires_in: 600
      })

    assert grant.scopes == ["hcp:general_preferences:read", "hcp:health_context:read"]
    assert {:ok, [listed]} = Vault.grants(vault)

    assert %{
             "grantId" => grant_id,
             "client" => %{"name" => "ChatGPT", "operator" => %{"name" => _operator}},
             "grantType" => "temporary",
             "status" => "active",
             "expiresAt" => expires_at
           } = listed

    assert grant_id == grant.grant_id
    assert is_binary(expires_at)
    assert Vault.purposes(listed) == ["Answer the person's message"]
  end

  test "an assistant receives a disclosure, not the stored memory", %{vault: vault} do
    saved = remember!(vault, :person, "I prefer window seats.")
    grant = grant!(vault, @chatgpt)

    assert {:ok, [disclosure]} = Vault.recall(vault, grant, "window seats")

    assert Vault.preference(disclosure) == "I prefer window seats."
    assert Vault.category(disclosure) == "general_preferences"
    assert Vault.declaration(disclosure) == "person-declared"
    assert is_binary(disclosure["ref"]) and is_binary(disclosure["useUntil"])
    refute Map.has_key?(disclosure, "id")
    refute disclosure["ref"] =~ String.replace_prefix(saved["id"], "urn:uuid:", "")
  end

  test "an assistant recalls only within its grant; outside it the vault refuses", %{vault: vault} do
    remember!(vault, :person, "I am allergic to penicillin.", %{category: "health_context"})
    grant = grant!(vault, @chatgpt, %{categories: ["health_context"]})

    assert {:ok, [_entry]} = Vault.recall(vault, grant, "allergic")

    assert {:error, %{status: 403, type: "scope-denied"}} =
             Vault.recall(vault, grant, "anything", categories: ["work_context"])
  end

  test "a grant narrowed to memories reads only those, and says so", %{vault: vault} do
    kept = remember!(vault, :person, "I run marathons.")
    remember!(vault, :person, "I run a bakery.")
    grant = grant!(vault, @chatgpt, %{actions: ["read", "write"], restrict_to: [kept["id"]]})

    assert {:ok, [listed]} = Vault.grants(vault)
    assert Vault.narrowed_to(listed) == [kept["id"]]

    assert {:ok, entries} = Vault.recall(vault, grant, "What do I run?")
    assert Enum.map(entries, &Vault.preference/1) == ["I run marathons."]
    # Narrowing reads leaves the write the person also granted.
    assert {:ok, _written} =
             Vault.remember(vault, grant.token, %{
               text: "Runs often.",
               category: "general_preferences"
             })
  end

  test "revoking a grant cuts the assistant off at its next request", %{vault: vault} do
    remember!(vault, :person, "I prefer window seats.")
    grant = grant!(vault, @chatgpt)
    assert {:ok, [_entry]} = Vault.recall(vault, grant, "window seats")

    assert :ok = Vault.revoke(vault, grant.grant_id)

    assert {:ok, [%{"status" => "revoked"}]} = Vault.grants(vault)

    assert {:error, %{status: 401, type: "invalid-token"}} =
             Vault.recall(vault, grant, "window seats")
  end

  test "what the person writes is authenticated; what an assistant says they said is not", %{
    vault: vault
  } do
    remember!(vault, :person, "I am vegetarian.")
    grant = grant!(vault, @claude, %{actions: ["read", "write"]})
    remember!(vault, grant.token, "Prefers aisle seats.")

    assert Vault.assurance(stored(vault, "I am vegetarian.")) == "authenticated"
    assert Vault.assurance(stored(vault, "Prefers aisle seats.")) == "unverified"
    refute Vault.confirmed?(stored(vault, "Prefers aisle seats."))
  end

  test "the person confirms an assistant's memory, and the assistant is told it stands", %{
    vault: vault
  } do
    grant = grant!(vault, @claude, %{actions: ["read", "write"]})
    remember!(vault, grant.token, "Prefers aisle seats.")

    assert {:ok, confirmed} =
             Vault.confirm(vault, stored(vault, "Prefers aisle seats."), "confirmed")

    assert Vault.confirmed?(confirmed)
    assert Vault.declaration(confirmed) == "person-declared"
    assert {:ok, [disclosure]} = Vault.recall(vault, grant, "aisle seats")
    assert Vault.confirmed?(disclosure)
  end

  test "a memory the person rejects is deleted and no longer recalled", %{vault: vault} do
    grant = grant!(vault, @claude, %{actions: ["read", "write"]})
    remember!(vault, grant.token, "Loves steak.")

    assert {:ok, rejected} = Vault.confirm(vault, stored(vault, "Loves steak."), "rejected")

    assert Vault.status(rejected) == "deleted"
    assert {:ok, []} = Vault.recall(vault, grant, "steak")
  end

  test "an assistant's inference that contradicts the person is quarantined, not recalled", %{
    vault: vault
  } do
    remember!(vault, :person, "I am vegetarian.", %{dimension: "diet"})
    grant = grant!(vault, @claude, %{actions: ["read", "write"]})

    remember!(vault, grant.token, "I am not vegetarian.", %{
      dimension: "diet",
      declaration_type: "model-inferred",
      confidence: "medium"
    })

    assert Vault.status(stored(vault, "I am not vegetarian.")) == "conflicted"
    assert Vault.status(stored(vault, "I am vegetarian.")) == "active"

    assert {:ok, entries} = Vault.recall(vault, grant, "vegetarian")
    assert Enum.map(entries, &Vault.preference/1) == ["I am vegetarian."]

    assert {:ok, events} = Vault.audit(vault)
    assert Enum.any?(events, &(&1["eventType"] == "conflict.detected"))
  end

  test "accepting a quarantined inference makes it active and sets the person's statement aside",
       %{
         vault: vault
       } do
    remember!(vault, :person, "I am vegetarian.")
    grant = grant!(vault, @claude, %{actions: ["read", "write"]})

    remember!(vault, grant.token, "I am not vegetarian.", %{
      declaration_type: "model-inferred",
      confidence: "medium"
    })

    assert {:ok, accepted} =
             Vault.confirm(vault, stored(vault, "I am not vegetarian."), "confirmed")

    assert Vault.status(accepted) == "active"
    assert Vault.declaration(accepted) == "model-inferred"
    assert Vault.status(stored(vault, "I am vegetarian.")) == "deprecated"
  end

  test "the audit log shows each grant, read and revocation, newest first", %{vault: vault} do
    remember!(vault, :person, "I prefer window seats.")
    grant = grant!(vault, @chatgpt)
    {:ok, _entries} = Vault.recall(vault, grant, "window seats", purpose: "Booking a flight")
    :ok = Vault.revoke(vault, grant.grant_id)

    assert {:ok, [revoked, read, issued, created]} = Vault.audit(vault)

    assert Enum.map([revoked, read, issued, created], & &1["eventType"]) ==
             ~w(grant.revoked context.read grant.issued context.created)

    assert read["purposeDescription"] == "Booking a flight"
    assert read["grantId"] == grant.grant_id
  end

  test "export hands the person the whole vault as JSON", %{vault: vault} do
    remember!(vault, :person, "I prefer window seats.")

    assert {:ok, json} = Vault.export(vault)
    assert %{"type" => "ContextExport", "entries" => [entry]} = Jason.decode!(json)
    assert Vault.preference(entry) == "I prefer window seats."
  end
end
