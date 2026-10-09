defmodule HcpConformance.Checks.Entries do
  @moduledoc """
  The entry lifecycle over REST (§3.3.2 to §3.3.4, §3.3.6) and the data model it
  must produce (§2.2): server-assigned fields, validation, versioning, soft and
  hard deletion, and the audit event each operation appends (§4.3.1).
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context, Envelope, Fixtures}

  def group, do: "entries"

  def checks do
    person = [requires: [:rest, :person]]

    [
      Check.new(
        "entries.add",
        "3.3.2",
        :must,
        "POST /v1/preferences creates the entry and assigns id, status, version and issuanceDate",
        &add/1,
        person
      ),
      Check.new(
        "entries.envelope_valid",
        "2.2",
        :must,
        "A created entry satisfies the data-model rules of the common envelope",
        &envelope_valid/1,
        person
      ),
      Check.new(
        "entries.envelope_form",
        "2.2.1",
        :must,
        "Entries are returned in the envelope form the discovery document declares",
        &envelope_form/1,
        person
      ),
      Check.new(
        "entries.inferred_requires_confidence",
        "2.2.2",
        :must,
        "A model-inferred write without confidence is rejected with 422 malformed-request",
        &inferred_requires_confidence/1,
        person
      ),
      Check.new(
        "entries.confidence_only_inferred",
        "2.2.2",
        :must,
        "A write with confidence on an entry that is not model-inferred is rejected with 422 malformed-request",
        &confidence_only_inferred/1,
        person
      ),
      Check.new(
        "entries.required_fields",
        "3.4.4",
        :must,
        "A write missing record.category or record.declarationType is rejected with 422 malformed-request",
        &required_fields/1,
        person
      ),
      Check.new(
        "entries.add_audited",
        "4.3.1",
        :must,
        "Adding an entry appends preference.created",
        &add_audited/1,
        person
      ),
      Check.new(
        "entries.get",
        "3.3.6",
        :must,
        "GET /v1/preferences/{id} returns the entry inside the response envelope",
        &get/1,
        person
      ),
      Check.new(
        "entries.get_requires_purpose",
        "3.3.6",
        :must,
        "GET /v1/preferences/{id} without a purpose is refused",
        &get_requires_purpose/1,
        person
      ),
      Check.new(
        "entries.get_audited",
        "3.3.6",
        :must,
        "Reading an entry appends preference.read with the stated purpose",
        &get_audited/1,
        person
      ),
      Check.new(
        "entries.update",
        "3.3.3",
        :must,
        "PUT increments record.version by one, sets previousVersion and keeps the id",
        &update/1,
        person
      ),
      Check.new(
        "entries.get_version",
        "3.3.6",
        :must,
        "GET with ?version=n returns that version of the entry",
        &get_version/1,
        person
      ),
      Check.new(
        "entries.update_audited",
        "4.3.1",
        :must,
        "Updating an entry appends preference.updated",
        &update_audited/1,
        person
      ),
      Check.new(
        "entries.soft_delete",
        "3.3.4",
        :must,
        "DELETE marks the entry deleted and answers with the deletion record",
        &soft_delete/1,
        person
      ),
      Check.new(
        "entries.soft_delete_audited",
        "4.3.1",
        :must,
        "A soft delete appends preference.deleted",
        &soft_delete_audited/1,
        person
      ),
      Check.new(
        "entries.hard_delete",
        "3.3.4",
        :must,
        "DELETE ?hardDelete=true removes the entry permanently at the person's request",
        &hard_delete/1,
        person
      ),
      Check.new(
        "entries.hard_delete_audited",
        "4.3.1",
        :must,
        "A hard delete appends preference.hardDeleted",
        &hard_delete_audited/1,
        person
      ),
      Check.new(
        "entries.nonexistent_is_403",
        "3.3.6",
        :must,
        "An agent asking for an entry that does not exist gets 403 scope-denied, not 404",
        &nonexistent_is_403/1,
        requires: [:rest, :agent]
      ),
      Check.new(
        "entries.write_needs_write_scope",
        "4.1",
        :must,
        "A client holding only read cannot add an entry",
        &write_needs_write_scope/1,
        requires: [:rest, :hook]
      )
    ]
  end

  defp add(ctx) do
    word = Context.unique_word(ctx)
    preference = "I prefer aisle seats " <> word
    entry = Fixtures.create!(ctx, Context.person!(ctx), preference: preference)
    form = ctx.envelope_form
    field = &Envelope.get(entry, form, &1)

    Assert.check!(
      Envelope.urn_uuid?(entry["id"]),
      "id must be a server-assigned urn:uuid, got #{inspect(entry["id"])}"
    )

    Assert.check!(
      field.(["record", "status"]) == "active",
      "record.status must be active, got #{inspect(field.(["record", "status"]))}"
    )

    Assert.check!(
      field.(["record", "version"]) == 1,
      "record.version must be 1, got #{inspect(field.(["record", "version"]))}"
    )

    Assert.check!(
      is_nil(field.(["record", "previousVersion"])),
      "record.previousVersion must be null at version 1"
    )

    Assert.check!(
      Envelope.iso8601?(field.(["claim", "issuanceDate"])),
      "claim.issuanceDate must be assigned by the server at Tier 1"
    )

    Assert.check!(
      field.(["claim", "subject", "preference"]) == preference,
      "the preference statement was not stored as sent"
    )

    Assert.check!(
      field.(["record", "category"]) == ctx.primary_category,
      "record.category was not stored as sent"
    )

    Assert.check!(
      field.(["record", "declarationType"]) == "user-declared",
      "record.declarationType was not stored as sent"
    )

    Assert.check!(
      field.(["record", "provenance", "source"]) == "conversation-id:hcp-conformance-" <> ctx.nonce,
      "record.provenance.source (client-assigned) was not stored as sent"
    )
  end

  defp envelope_valid(ctx) do
    entry = Fixtures.create!(ctx, Context.person!(ctx))
    violations = Envelope.validate(entry, ctx.envelope_form)
    Assert.check!(violations == [], Enum.join(violations, "; "))
  end

  defp envelope_form(ctx) do
    entry = Fixtures.create!(ctx, Context.person!(ctx))

    case ctx.envelope_form do
      "grouped" ->
        Assert.check!(
          is_map(entry["claim"]) and is_map(entry["record"]) and not Map.has_key?(entry, "category"),
          "the declared form is grouped, but the entry does not carry claim and record objects"
        )

      "flat" ->
        Assert.check!(
          Map.has_key?(entry, "category") and not Map.has_key?(entry, "record"),
          "the declared form is flat, but the entry nests record members"
        )
    end
  end

  defp writer(ctx), do: if(ctx.agent, do: ctx.agent.token, else: Context.person!(ctx))

  defp inferred_requires_confidence(ctx) do
    body =
      Fixtures.entry_body(ctx, declaration_type: "model-inferred", confidence: nil)
      |> drop_confidence(ctx.envelope_form)

    response = Context.request(ctx, :post, Context.url(ctx, :preferences), token: writer(ctx), json: body)
    Assert.problem!(response, 422, "malformed-request", "model-inferred entry without confidence")
  end

  defp drop_confidence(body, "flat"), do: Map.delete(body, "confidence")
  defp drop_confidence(body, _grouped), do: update_in(body, ["record"], &Map.delete(&1, "confidence"))

  defp confidence_only_inferred(ctx) do
    body = Fixtures.entry_body(ctx, declaration_type: "user-declared", confidence: "high")

    response =
      Context.request(ctx, :post, Context.url(ctx, :preferences), token: Context.person!(ctx), json: body)

    Assert.problem!(response, 422, "malformed-request", "user-declared entry with confidence")
  end

  defp required_fields(ctx) do
    for path <- [["record", "category"], ["record", "declarationType"]] do
      body = Fixtures.entry_body(ctx, drop: [path])

      response =
        Context.request(ctx, :post, Context.url(ctx, :preferences), token: Context.person!(ctx), json: body)

      Assert.problem!(response, 422, "malformed-request", "entry without #{Enum.join(path, ".")}")
    end
  end

  defp add_audited(ctx) do
    entry = Fixtures.create!(ctx, Context.person!(ctx))

    AuditLog.await!(
      ctx,
      "preference.created",
      &AuditLog.event?(&1, "preference.created", entryId: entry["id"])
    )
  end

  defp get(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    response = Fixtures.get(ctx, token, entry["id"])
    Assert.status!(response, 200, "GET /v1/preferences/{id}")
    body = Assert.json_object!(response, "GET /v1/preferences/{id}")

    Assert.check!(
      is_map(body["entry"]) and body["entry"]["id"] == entry["id"],
      "the body must carry the entry under \"entry\""
    )

    Assert.check!(is_binary(body["retrievalId"]), "the body must carry a retrievalId")
    Assert.check!(Envelope.iso8601?(body["timestamp"]), "the body must carry an ISO-8601 timestamp")

    Assert.check!(
      is_map(body["minimization"]) and is_binary(body["minimization"]["method"]) and
        is_list(body["minimization"]["redactedFields"]),
      "the body must carry a minimization object with method and redactedFields (§4.4.5)"
    )
  end

  defp get_requires_purpose(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    response = Context.request(ctx, :get, Context.entry_url(ctx, entry["id"]), token: token)
    Assert.refused!(response, "GET /v1/preferences/{id} without purpose")
  end

  defp get_audited(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    purpose = "Conformance read " <> Context.unique_word(ctx)
    response = Fixtures.get(ctx, token, entry["id"], purpose: purpose)
    Assert.status!(response, 200, "GET /v1/preferences/{id}")

    AuditLog.await!(
      ctx,
      "preference.read",
      &AuditLog.event?(&1, "preference.read", entryId: entry["id"], purpose: purpose),
      read?: true
    )
  end

  @spec update!(Context.t(), String.t(), String.t(), String.t()) :: map()
  def update!(ctx, token, id, text) do
    response =
      Context.request(ctx, :put, Context.entry_url(ctx, id),
        token: token,
        json: %{"updatedPreference" => text, "reason" => "HCP conformance check"}
      )

    Assert.status!(response, 200, "PUT /v1/preferences/{id}")
    Assert.json_object!(response, "PUT /v1/preferences/{id}")
  end

  defp update(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    text = "Updated statement " <> Context.unique_word(ctx)
    updated = update!(ctx, token, entry["id"], text)
    field = &Envelope.get(updated, ctx.envelope_form, &1)

    Assert.check!(updated["id"] == entry["id"], "the id changed on update")

    Assert.check!(
      field.(["record", "version"]) == 2,
      "record.version must be 2, got #{inspect(field.(["record", "version"]))}"
    )

    Assert.check!(field.(["record", "previousVersion"]) == 1, "record.previousVersion must be 1")
    Assert.check!(field.(["claim", "subject", "preference"]) == text, "the updated statement was not stored")
    violations = Envelope.validate(updated, ctx.envelope_form)
    Assert.check!(violations == [], "the updated entry is invalid: " <> Enum.join(violations, "; "))
  end

  defp get_version(ctx) do
    token = Context.person!(ctx)
    original = "Original statement " <> Context.unique_word(ctx)
    entry = Fixtures.create!(ctx, token, preference: original)
    update!(ctx, token, entry["id"], "Revised statement " <> Context.unique_word(ctx))
    response = Fixtures.get(ctx, token, entry["id"], version: 1)
    Assert.status!(response, 200, "GET /v1/preferences/{id}?version=1")
    body = Assert.json_object!(response, "GET ?version=1")
    first = body["entry"] || %{}

    Assert.check!(
      Envelope.get(first, ctx.envelope_form, ["record", "version"]) == 1,
      "?version=1 did not return version 1"
    )

    Assert.check!(
      Envelope.get(first, ctx.envelope_form, ["claim", "subject", "preference"]) == original,
      "?version=1 did not return the original statement"
    )
  end

  defp update_audited(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    update!(ctx, token, entry["id"], "Revised " <> Context.unique_word(ctx))

    AuditLog.await!(
      ctx,
      "preference.updated",
      &AuditLog.event?(&1, "preference.updated", entryId: entry["id"])
    )
  end

  @spec delete!(Context.t(), String.t(), String.t(), keyword()) :: map()
  def delete!(ctx, token, id, params \\ []) do
    response = Context.request(ctx, :delete, Context.entry_url(ctx, id), token: token, params: params)
    Assert.status!(response, 200, "DELETE /v1/preferences/{id}")
    Assert.json_object!(response, "DELETE /v1/preferences/{id}")
  end

  defp soft_delete(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    body = delete!(ctx, token, entry["id"])

    Assert.check!(body["entryId"] == entry["id"], "the response must name the entryId")
    Assert.check!(body["status"] == "deleted", "the response status must be \"deleted\"")
    Assert.check!(body["hardDeleted"] == false, "hardDeleted must be false for a soft delete")
    Assert.check!(Envelope.iso8601?(body["timestamp"]), "the response must carry an ISO-8601 timestamp")
  end

  defp soft_delete_audited(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    delete!(ctx, token, entry["id"])

    AuditLog.await!(
      ctx,
      "preference.deleted",
      &AuditLog.event?(&1, "preference.deleted", entryId: entry["id"])
    )
  end

  defp hard_delete(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    body = delete!(ctx, token, entry["id"], hardDelete: true)
    Assert.check!(body["hardDeleted"] == true, "hardDeleted must be true")
    response = Fixtures.get(ctx, token, entry["id"])
    Assert.check!(response.status != 200, "the entry is still readable after a hard delete")
  end

  defp hard_delete_audited(ctx) do
    token = Context.person!(ctx)
    entry = Fixtures.create!(ctx, token)
    delete!(ctx, token, entry["id"], hardDelete: true)

    AuditLog.await!(
      ctx,
      "preference.hardDeleted",
      &AuditLog.event?(&1, "preference.hardDeleted", entryId: entry["id"])
    )
  end

  defp nonexistent_is_403(ctx) do
    id = "urn:uuid:" <> uuid4()
    response = Fixtures.get(ctx, Context.agent!(ctx).token, id)
    Assert.problem!(response, 403, "scope-denied", "an agent reading a non-existent entry")
  end

  defp write_needs_write_scope(ctx) do
    grant = Context.issue_grant!(ctx, scopes: Context.scopes(ctx.primary_category, ["read"]))

    response =
      Context.request(ctx, :post, Context.url(ctx, :preferences),
        token: grant.token,
        json: Fixtures.entry_body(ctx)
      )

    Assert.problem!(response, 403, "scope-denied", "a read-only client adding an entry")
  end

  @doc "A random version 4 UUID."
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [u0, u1, u2, u3, u4]) |> to_string()
  end
end
