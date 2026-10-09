defmodule HcpConformance.Reference.Store do
  @moduledoc """
  State of the reference server: subjects with their entries, grants, audit log,
  idempotency keys and cursors, and the token table that routes a bearer to its
  subject. In memory only; the oldest subjects are evicted past a cap, so a public
  demo cannot be used to fill memory.
  """

  use Agent

  @max_subjects 1_000

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{subjects: %{}, tokens: %{}, order: []} end, Keyword.take(opts, [:name]))
  end

  @doc "Runs `fun` on the state atomically; `fun` returns `{reply, new_state}`."
  @spec transaction(Agent.agent(), (map() -> {term(), map()})) :: term()
  def transaction(store, fun), do: Agent.get_and_update(store, fun, 15_000)

  @doc "Adds a subject, evicting the oldest past the cap."
  @spec put_subject(map(), map()) :: map()
  def put_subject(state, subject) do
    state = %{
      state
      | subjects: Map.put(state.subjects, subject.id, subject),
        tokens: Map.put(state.tokens, subject.person_token, {subject.id, :person}),
        order: state.order ++ [subject.id]
    }

    if length(state.order) > @max_subjects, do: drop_subject(state, hd(state.order)), else: state
  end

  @doc "Removes a subject and every token routing to it."
  @spec drop_subject(map(), String.t()) :: map()
  def drop_subject(state, subject_id) do
    tokens = state.tokens |> Enum.reject(fn {_token, {id, _kind}} -> id == subject_id end) |> Map.new()

    %{
      state
      | subjects: Map.delete(state.subjects, subject_id),
        tokens: tokens,
        order: List.delete(state.order, subject_id)
    }
  end
end
