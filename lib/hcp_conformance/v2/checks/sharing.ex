defmodule HcpConformance.V2.Checks.Sharing do
  @moduledoc """
  Onward sharing (§3.12, §5.2.8): a client may tell another organization what a
  task needs from Low-sensitivity context only where the person elected it on
  the grant, and reports every share. The provider records each report, the
  ones the grant did not allow included, because the share has already
  happened.
  """

  alias HcpConformance.{Assert, AuditLog, Check, Context}
  alias HcpConformance.V2.{Fixtures, Target}

  def group, do: "sharing"

  def checks do
    hook = [requires: [:rest, :person, :hook]]

    [
      Check.new(
        "sharing.low_sensitivity_only",
        "6.1.5",
        :must,
        "Onward sharing is refused for a detail with a category above Low sensitivity",
        &low_only/1,
        hook
      ),
      Check.new(
        "sharing.disclosure_flag",
        "7.4",
        :must,
        "A disclosure carries onwardSharing only under a grant that elected it",
        &disclosure_flag/1,
        hook
      ),
      Check.new(
        "sharing.report",
        "9.4.16",
        :must,
        "A reported share answers 204 and appends context.shared naming the entries by id, as permitted",
        &report/1,
        hook
      ),
      Check.new(
        "sharing.not_permitted",
        "5.2.8",
        :must,
        "A share the grant did not allow fails with 403 scope-denied and is recorded all the same, as not permitted",
        &not_permitted/1,
        hook
      )
    ]
  end

  defp person(ctx), do: Context.person!(ctx)

  # The grant election needs a Low-sensitivity category to share from.
  defp low!(ctx) do
    sensitivity =
      for %{"id" => id, "sensitivity" => level} <-
            List.wrap((ctx.discovery || %{})["supported_categories"]),
          into: %{},
          do: {id, level}

    if sensitivity[ctx.primary_category] != "low",
      do:
        Assert.skip!(
          "the category the run works in, #{ctx.primary_category}, is not Low sensitivity"
        )

    sensitivity
  end

  defp sharing_grant(ctx) do
    case Context.issue_grant(ctx, actions: ["read"], onward_sharing: %{}) do
      {:ok, grant} ->
        grant

      {:error, message} ->
        Assert.skip!("the implementation issues no grant with onwardSharing: " <> message)
    end
  end

  defp low_only(ctx) do
    sensitivity = low!(ctx)

    case Enum.find(sensitivity, fn {_id, level} -> level in ["medium", "high"] end) do
      nil ->
        Assert.skip!("the target holds no category above Low sensitivity")

      {category, level} ->
        case Context.issue_grant(ctx,
               actions: ["read"],
               categories: [category],
               onward_sharing: %{}
             ) do
          {:error, _refused} ->
            :ok

          {:ok, _grant} ->
            Assert.fail!(
              "a grant electing onward sharing was issued for #{category}, which is #{level} sensitivity"
            )
        end
    end
  end

  defp disclosed!(ctx, grant, word) do
    case Fixtures.found(ctx, grant.token, word) do
      [disclosure] -> disclosure
      other -> Assert.fail!("expected the one entry just written, got #{length(other)}")
    end
  end

  defp disclosure_flag(ctx) do
    low!(ctx)
    word = Context.unique_word(ctx)
    Fixtures.create!(ctx, person(ctx), value: "I wear size " <> word)
    plain = Context.issue_grant!(ctx, actions: ["read"])

    Assert.check!(
      not Map.has_key?(disclosed!(ctx, plain, word), "onwardSharing"),
      "a disclosure under a grant that did not elect onward sharing carries onwardSharing"
    )

    shared = disclosed!(ctx, sharing_grant(ctx), word)

    Assert.check!(
      shared["onwardSharing"] == true,
      "a disclosure under a grant that elected onward sharing must carry onwardSharing: true"
    )
  end

  @doc "The body of a share report (§5.2.8) for these refs."
  @spec share_body([String.t()]) :: map()
  def share_body(refs) do
    %{
      "recipient" => %{
        "domain" => "outfitters.conformance.hcp.example",
        "name" => "Conformance Outfitters"
      },
      "refs" => refs,
      "purpose" => Target.purpose(),
      "sharedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp share(ctx, grant, ref),
    do:
      Context.request(ctx, :post, Context.url(ctx, :shares),
        token: grant.token,
        json: share_body([ref])
      )

  @doc "Waits for the context.shared event that names an entry, and returns its `data`."
  @spec shared_event!(Context.t(), String.t(), boolean()) :: map()
  def shared_event!(ctx, entry_id, permitted) do
    match = fn event ->
      AuditLog.event?(event, "context.shared") and
        entry_id in List.wrap(get_in(event, ["data", "entries"])) and
        get_in(event, ["data", "permitted"]) == permitted
    end

    [event | _] =
      AuditLog.await!(
        ctx,
        "context.shared naming the entry by id, permitted: #{permitted}",
        match
      )

    event["data"]
  end

  defp report(ctx) do
    low!(ctx)
    word = Context.unique_word(ctx)
    entry = Fixtures.create!(ctx, person(ctx), value: "I wear size " <> word)
    grant = sharing_grant(ctx)
    response = share(ctx, grant, disclosed!(ctx, grant, word)["ref"])
    Assert.status!(response, 204, "POST /v2/shares")
    data = shared_event!(ctx, entry["id"], true)

    Assert.check!(
      get_in(data, ["recipient", "domain"]) == "outfitters.conformance.hcp.example",
      "context.shared must record the recipient"
    )

    Assert.check!(data["purpose"] == Target.purpose(), "context.shared must record the purpose")
  end

  defp not_permitted(ctx) do
    word = Context.unique_word(ctx)
    entry = Fixtures.create!(ctx, person(ctx), value: "I wear size " <> word)
    grant = Context.issue_grant!(ctx, actions: ["read"])
    response = share(ctx, grant, disclosed!(ctx, grant, word)["ref"])

    Assert.problem!(
      response,
      403,
      "scope-denied",
      "a share under a grant that did not elect onward sharing"
    )

    shared_event!(ctx, entry["id"], false)
  end
end
