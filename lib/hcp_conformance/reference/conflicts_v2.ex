defmodule HcpConformance.Reference.ConflictsV2 do
  @moduledoc """
  Relationships between entries and what follows when two conflict (HCP v2
  §4.2.3, §4.7), with the Memory Manager Profile's detection (§15), for the v2
  reference implementation.

  Two entries conflict when a `contradicts` relationship links them, whoever
  asserted it: a client with a write, or the provider's own method. What changes
  then depends on standing, never on declaration type alone (§4.7.1): the entry
  that is not authoritative is quarantined, both are where neither is, and
  nothing changes between two of the person's own statements. Only the person
  resolves a conflict, by rejecting, accepting or revising; the one exception is
  an asserter's later inference, which deprecates its earlier one.

  The reference's detection method, declared as `term-negation`, finds a
  contradiction between two entries that share a category where one statement
  is the plain negation of the other ("I am vegetarian", "I am not vegetarian").
  A shared dimension alone is never enough (§15.2).

  Each function takes the subject's state and returns it with the audit events
  to append, as `{type, entry_id, related_entry_id, data}`. A subject keeps its
  open conflicts in `conflicts`: the two entries, who asserted the relationship,
  and which entries the conflict quarantined.
  """

  @types ~w(derivedFrom supersedes contradicts duplicates)
  @acts ~w(reject accept supersede)
  @negations ~w(not no never non without)
  @filler ~w(i am is are was the a an person user they he she it do does to be my their)

  @type subject :: map()
  @type event :: {String.t(), String.t(), String.t() | nil, map()}

  @doc "The declared detection method (§15.2, §19.3)."
  @spec method() :: String.t()
  def method, do: "term-negation"

  # Reading a write's relationships (§5.2.3) ---------------------------------------------

  @doc """
  The relationships a create or revise asserts, with each target named as the
  caller names entries and `resolve` turning that into an entry the caller may
  relate to. `{:error, slug, detail}` is the Core error for one that is
  malformed, or whose target the caller cannot read, which is not authorized
  whether or not the target exists.
  """
  @spec parse(term(), (String.t() -> {:ok, String.t()} | :error)) ::
          {:ok, [map()]} | {:error, String.t(), String.t()}
  def parse(nil, _resolve), do: {:ok, []}

  def parse(relationships, resolve) when is_list(relationships) do
    Enum.reduce_while(relationships, {:ok, []}, fn relationship, {:ok, parsed} ->
      case relationship(relationship, resolve) do
        {:ok, one} -> {:cont, {:ok, parsed ++ [one]}}
        error -> {:halt, error}
      end
    end)
  end

  def parse(_relationships, _resolve),
    do: {:error, "malformed-request", "record.relationships must be an array"}

  defp relationship(%{"type" => type, "target" => target} = given, resolve)
       when type in @types and is_binary(target) do
    with {:ok, id} <- resolve.(target),
         {:ok, proposal} <- proposal(given["proposal"], resolve) do
      {:ok, %{type: type, target: id, proposal: proposal}}
    else
      :error -> {:error, "scope-denied", "The request falls outside the caller's grant"}
      error -> error
    end
  end

  defp relationship(_other, _resolve),
    do: {:error, "malformed-request", "a relationship names a type and a target"}

  defp proposal(nil, _resolve), do: {:ok, nil}

  defp proposal(%{"act" => act, "entry" => entry} = given, resolve)
       when act in @acts and is_binary(entry) do
    with {:ok, id} <- resolve.(entry) do
      {:ok, given |> Map.take(["act", "rationale", "weighed"]) |> Map.put("entry", id)}
    end
  end

  defp proposal(_other, _resolve),
    do: {:error, "malformed-request", "a proposal names an act and the entry it applies to"}

  # Asserting a relationship (§4.2.3) ---------------------------------------------------

  @doc """
  Records a relationship from `id` to its target, as `asserter` (a role and an
  identifier) asserted it. A `contradicts` relationship is recorded on both
  entries and opens a conflict; a `supersedes` relationship deprecates its
  target where a Management Client, or the target's own asserter, asserted it.
  """
  @spec link(subject(), String.t(), map(), map(), String.t(), MapSet.t()) ::
          {subject(), [event()]}
  def link(subject, id, %{type: "contradicts"} = relationship, asserter, now, faults) do
    target = relationship.target
    proposal = relationship.proposal && stamp(relationship.proposal, asserter, now)

    record =
      &compact(%{
        "type" => "contradicts",
        "target" => &1,
        "assertedBy" => asserter,
        "recordedAt" => now,
        "proposal" => proposal
      })

    subject = relate(subject, id, record.(target))

    subject =
      if MapSet.member?(faults, :asymmetric_relationship),
        do: subject,
        else: relate(subject, target, record.(id))

    {subject, events} = open(subject, id, target, asserter["role"], faults)
    {subject, proposed} = propose(subject, id, target, proposal, faults)
    {subject, events ++ proposed}
  end

  def link(subject, id, relationship, asserter, now, _faults) do
    record = %{
      "type" => relationship.type,
      "target" => relationship.target,
      "assertedBy" => asserter,
      "recordedAt" => now
    }

    subject = relate(subject, id, record)
    target = current(subject, relationship.target)

    deprecates? =
      relationship.type == "supersedes" and
        (asserter["role"] == "management-client" or
           asserter_of(target) == asserter_of(current(subject, id)))

    {if(deprecates?, do: set_status(subject, relationship.target, "deprecated"), else: subject),
     []}
  end

  # §4.7.4: proposedBy and proposedAt are the provider's, never a request's.
  defp stamp(proposal, asserter, now),
    do: Map.merge(proposal, %{"proposedBy" => asserter, "proposedAt" => now})

  defp propose(subject, _id, _target, nil, _faults), do: {subject, []}

  defp propose(subject, id, target, proposal, faults) do
    {conflicted, other} = roles(subject, id, target)
    data = Map.take(proposal, ["act", "entry", "weighed", "proposedBy"])
    event = {"conflict.proposed", conflicted, other, data}

    # The fault carries a proposal out, which only the person's act may do.
    if MapSet.member?(faults, :apply_proposal) do
      status = if proposal["act"] == "reject", do: "deleted", else: "active"
      {set_status(subject, proposal["entry"], status), [event]}
    else
      {subject, [event]}
    end
  end

  # Conflicts (§4.7) -------------------------------------------------------------------

  # Opens the conflict between two entries and applies what follows from their standing.
  defp open(subject, id, other, by, faults) do
    [first, second] =
      Enum.sort_by([id, other], &Enum.find_index(subject.entry_order, fn held -> held == &1 end))

    detected = {"conflict.detected", nil, nil, %{}}

    {subject, events} =
      case consequence(current(subject, first), current(subject, second)) do
        {:deprecate, earlier} ->
          # An asserter corrected itself: the one conflict a provider settles.
          resolved =
            {"conflict.resolved", earlier, second,
             %{"transition" => "asserter-superseded", "proposal" => false}}

          {set_status(subject, earlier, "deprecated"),
           [put_ids(detected, earlier, second), resolved]}

        {:quarantine, ids} ->
          ids = if MapSet.member?(faults, :no_quarantine), do: [], else: ids
          subject = Enum.reduce(ids, subject, &set_status(&2, &1, "conflicted"))

          subject =
            update_in(subject.conflicts, &(&1 ++ [%{ids: [id, other], by: by, quarantined: ids}]))

          {conflicted, standing} = roles(subject, id, other)
          {subject, [put_ids(detected, conflicted, standing)]}
      end

    {subject,
     if(MapSet.member?(faults, :conflict_unaudited), do: tl_or_empty(events), else: events)}
  end

  defp tl_or_empty([_detected | rest]), do: rest

  defp put_ids({type, _entry, _related, data}, entry, related), do: {type, entry, related, data}

  # §8.2: the conflicted entry and the authoritative one; where neither or both
  # are authoritative, simply the two.
  defp roles(subject, id, other) do
    case Enum.filter([id, other], &authoritative?(current(subject, &1))) do
      [standing] -> {hd([id, other] -- [standing]), standing}
      _neither_or_both -> {id, other}
    end
  end

  @doc """
  What a conflict between two entries changes (§4.7), the first recorded
  earlier: `{:deprecate, id}` where one asserter's later inference corrects its
  earlier one, otherwise the entries to quarantine, which may be none.
  """
  @spec consequence(map(), map()) :: {:deprecate, String.t()} | {:quarantine, [String.t()]}
  def consequence(first, second) do
    pair = [first, second]
    standing = Enum.filter(pair, &authoritative?/1)

    cond do
      not Enum.any?(pair, &inferred?/1) or length(standing) == 2 ->
        {:quarantine, []}

      standing == [] and Enum.all?(pair, &inferred?/1) and
          asserter_of(first) == asserter_of(second) ->
        {:deprecate, first["id"]}

      true ->
        {:quarantine, Enum.map(pair -- standing, & &1["id"])}
    end
  end

  @doc """
  Whether an entry has the standing of the person's own statement (§4.7.1): a
  person-declared entry the provider authenticated, or any entry whose latest
  confirmation on this version is `confirmed`.
  """
  @spec authoritative?(map()) :: boolean()
  def authoritative?(entry) do
    provenance = entry["record"]["provenance"]

    (entry["assertion"]["declarationType"] == "person-declared" and
       provenance["assertedBy"]["assurance"] in ["authenticated", "cryptographically-verified"]) or
      match?(%{"disposition" => "confirmed"}, List.last(provenance["confirmations"] || []))
  end

  defp inferred?(entry), do: entry["assertion"]["declarationType"] == "model-inferred"
  defp asserter_of(entry), do: entry["record"]["provenance"]["assertedBy"]["id"]

  # Detection (§15.2) -------------------------------------------------------------------

  @doc """
  Evaluates the entry against every other active entry, as on every write, and
  records the conflicts the method finds as the provider's own.
  """
  @spec detect(subject(), String.t(), String.t(), String.t(), MapSet.t()) ::
          {subject(), [event()]}
  def detect(subject, id, provider, now, faults) do
    entry = current(subject, id)
    asserter = %{"role" => "hcp-provider", "id" => provider}
    loose? = MapSet.member?(faults, :dimension_alone)

    subject.entry_order
    |> Enum.reject(&(&1 == id or related?(entry, &1)))
    |> Enum.filter(&candidate?(entry, current(subject, &1), loose?))
    |> Enum.reduce({subject, []}, fn other, {subject, events} ->
      relationship = %{type: "contradicts", target: other, proposal: nil}
      {subject, more} = link(subject, id, relationship, asserter, now, faults)
      {subject, events ++ more}
    end)
  end

  defp related?(entry, other),
    do:
      Enum.any?(
        entry["record"]["relationships"],
        &(&1["type"] == "contradicts" and &1["target"] == other)
      )

  # A candidate pair holds a model-inferred entry, both active (§15.2).
  defp candidate?(entry, other, loose?) do
    Enum.all?([entry, other], &(&1["record"]["status"] == "active")) and
      Enum.any?([entry, other], &inferred?/1) and contradiction?(entry, other, loose?)
  end

  @doc """
  The reference's method: the entries share a category, do not name different
  dimensions, and one statement is the other's negation. `loose?` is a fault:
  a shared dimension alone, which the profile forbids.
  """
  @spec contradiction?(map(), map(), boolean()) :: boolean()
  def contradiction?(a, b, loose? \\ false) do
    shared? =
      Enum.any?(a["classification"]["categories"], &(&1 in b["classification"]["categories"]))

    dimensions = Enum.map([a, b], &normalize(&1["classification"]["dimension"]))

    cond do
      not shared? ->
        false

      loose? ->
        match?([same, same] when is_binary(same), dimensions)

      match?([one, other] when is_binary(one) and is_binary(other) and one != other, dimensions) ->
        false

      true ->
        negation?(terms(a), terms(b))
    end
  end

  # §15.2: trim, lowercase, collapse whitespace to an underscore; a URI is compared as it is.
  defp normalize(nil), do: nil

  defp normalize(dimension) do
    if String.contains?(dimension, "://"),
      do: dimension,
      else: dimension |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "_")
  end

  defp terms(entry) do
    case entry["content"]["value"] do
      text when is_binary(text) ->
        text |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

      _object ->
        []
    end
  end

  defp negation?(a, b) do
    said = &Enum.sort(Enum.uniq(&1) -- (@negations ++ @filler))
    negated? = &Enum.any?(&1, fn term -> term in @negations end)
    said.(a) != [] and said.(a) == said.(b) and negated?.(a) != negated?.(b)
  end

  # The person's acts (§4.7.3) and re-evaluation (§15.3) ----------------------------------

  @doc """
  Applies a confirmation or a rejection of the entry to its open conflicts.
  Rejecting returns what the conflict quarantined to active. Accepting
  deprecates the entry that was authoritative; one that was not stays
  quarantined, for the person to act on.
  """
  @spec confirmed(subject(), String.t(), String.t()) :: {subject(), [event()]}
  def confirmed(subject, id, "rejected") do
    Enum.reduce(involving(subject, id), {subject, []}, fn conflict, {subject, events} ->
      other = hd(conflict.ids -- [id])
      event = resolved(subject, id, other, "rejected")
      {close(subject, conflict), events ++ [event]}
    end)
  end

  def confirmed(subject, id, _confirmed) do
    # Accepting concerns the conflicts that quarantined this entry.
    quarantining = Enum.filter(involving(subject, id), &(id in &1.quarantined))

    Enum.reduce(quarantining, {subject, []}, fn conflict, {subject, events} ->
      other = hd(conflict.ids -- [id])
      event = resolved(subject, id, other, "accepted")

      subject =
        if other in conflict.quarantined,
          do: requarantine(subject, conflict, [other]),
          else: subject |> close(conflict) |> deprecate(other)

      {subject, events ++ [event]}
    end)
  end

  defp resolved(subject, id, other, transition) do
    data = %{"transition" => transition, "proposal" => followed?(subject, id, other, transition)}
    {"conflict.resolved", id, other, data}
  end

  # §4.7.3: an attestation is never deprecated by the person's acceptance of another entry.
  defp deprecate(subject, id) do
    if current(subject, id)["assertion"]["declarationType"] == "issuer-attested",
      do: subject,
      else: set_status(subject, id, "deprecated")
  end

  # Whether the act is the one a proposal on the relationship named (§4.7.4).
  defp followed?(subject, id, other, transition) do
    act = if transition == "rejected", do: "reject", else: "accept"

    Enum.any?(current(subject, id)["record"]["relationships"], fn relationship ->
      relationship["target"] == other and
        match?(%{"act" => ^act, "entry" => ^id}, relationship["proposal"])
    end)
  end

  @doc """
  Re-evaluates the entry's open conflicts after a revision, whose new version
  starts with no relationships. A conflict a client asserted ends unless the
  revision asserts it again (`reasserted`, the targets it names); one the
  provider found ends unless its method still finds it. Where a conflict ends,
  what it quarantined returns to active.
  """
  @spec revised(subject(), String.t(), [String.t()], MapSet.t()) :: {subject(), [event()]}
  def revised(subject, id, reasserted, faults) do
    Enum.reduce(involving(subject, id), {subject, []}, fn conflict, {subject, events} ->
      other = hd(conflict.ids -- [id])

      stands? =
        if conflict.by == "hcp-provider",
          do:
            MapSet.member?(faults, :no_reevaluation) or
              contradiction?(current(subject, id), current(subject, other)),
          else: other in reasserted

      # A reasserted relationship is recorded again by the revision itself.
      cond do
        stands? and conflict.by == "hcp-provider" ->
          {restore(subject, id, other), events}

        stands? ->
          {subject |> unrelate(other, id) |> close(conflict), events}

        true ->
          {subject |> unrelate(other, id) |> close(conflict),
           events ++ [ended(conflict, id, other, "superseded")]}
      end
    end)
  end

  # The provider's relationship, kept on the new version as it stood on the last.
  defp restore(subject, id, other) do
    [_revised, previous | _older] = subject.entries[id]

    kept =
      Enum.filter(
        previous["record"]["relationships"],
        &(&1["type"] == "contradicts" and &1["target"] == other)
      )

    Enum.reduce(kept, subject, &relate(&2, id, &1))
  end

  @doc """
  Applies a withdrawal to the entry's open conflicts. Withdrawing the
  authoritative entry leaves what it quarantined quarantined: an entry does not
  gain standing by the removal of what it contradicted. Withdrawing a
  quarantined entry, or either entry of a conflict that changed no status, ends
  the conflict.
  """
  @spec withdrawn(subject(), String.t(), MapSet.t()) :: {subject(), [event()]}
  def withdrawn(subject, id, faults) do
    Enum.reduce(involving(subject, id), {subject, []}, fn conflict, {subject, events} ->
      other = hd(conflict.ids -- [id])
      stays? = conflict.quarantined != [] and id not in conflict.quarantined

      if stays? and not MapSet.member?(faults, :reactivate_on_withdrawal),
        do: {subject, events},
        else: {close(subject, conflict), events ++ [ended(conflict, id, other, "ended")]}
    end)
  end

  defp ended(%{quarantined: []}, id, other, _transition),
    do: {"conflict.resolved", id, other, %{"transition" => "ended", "proposal" => false}}

  defp ended(conflict, id, other, transition) do
    {entry, related} = named(conflict, id, other)
    {"conflict.resolved", entry, related, %{"transition" => transition, "proposal" => false}}
  end

  # §8.2: an event names the conflicted entry first, where the conflict held one.
  defp named(%{quarantined: [held], ids: ids}, _id, _other), do: {held, hd(ids -- [held])}
  defp named(_conflict, id, other), do: {id, other}

  @doc "Forgets a hard-deleted entry's conflicts."
  @spec forget(subject(), String.t()) :: subject()
  def forget(subject, id),
    do: update_in(subject.conflicts, &Enum.reject(&1, fn c -> id in c.ids end))

  # State ------------------------------------------------------------------------------

  defp involving(subject, id), do: Enum.filter(subject.conflicts, &(id in &1.ids))

  # Ends a conflict: what it quarantined, and no other open conflict still
  # quarantines, returns to active.
  defp close(subject, conflict) do
    subject = drop(subject, conflict)
    held = Enum.flat_map(subject.conflicts, & &1.quarantined)

    conflict.quarantined
    |> Enum.filter(&(&1 not in held and status(subject, &1) == "conflicted"))
    |> Enum.reduce(subject, &set_status(&2, &1, "active"))
  end

  defp drop(subject, conflict), do: update_in(subject.conflicts, &List.delete(&1, conflict))

  defp requarantine(subject, conflict, quarantined) do
    subject = drop(subject, conflict)
    update_in(subject.conflicts, &(&1 ++ [%{conflict | quarantined: quarantined}]))
  end

  defp current(subject, id), do: hd(subject.entries[id])
  defp status(subject, id), do: current(subject, id)["record"]["status"]

  defp set_status(subject, id, status),
    do:
      update_in(subject.entries[id], fn [entry | older] ->
        [put_in(entry, ["record", "status"], status) | older]
      end)

  defp relate(subject, id, relationship) do
    update_in(subject.entries[id], fn [entry | older] ->
      [update_in(entry, ["record", "relationships"], &(&1 ++ [relationship])) | older]
    end)
  end

  defp unrelate(subject, id, target) do
    update_in(subject.entries[id], fn [entry | older] ->
      kept =
        &Enum.reject(&1, fn held -> held["type"] == "contradicts" and held["target"] == target end)

      [update_in(entry, ["record", "relationships"], kept) | older]
    end)
  end

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
