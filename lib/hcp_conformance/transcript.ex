defmodule HcpConformance.Transcript do
  @moduledoc """
  Every HTTP exchange of a run, in order, with credentials redacted.

  It serves two purposes. A failed check points at the exchanges it made, so the
  report shows exactly what was sent and what came back. And the post-run checks
  audit every response the target gave (`hcp_version`, content types, problem
  shapes) instead of each check repeating those assertions.

  Secrets (tokens, the hook secret, tokens a hook returned) are registered as they
  appear and replaced with `[redacted]` in everything stored.
  """

  use Agent

  @max_body_bytes 16_384

  @type exchange :: %{
          id: pos_integer(),
          check_id: String.t() | nil,
          kind: :target | :hook,
          method: String.t(),
          url: String.t(),
          request_headers: [{String.t(), String.t()}],
          request_body: String.t() | nil,
          status: integer() | nil,
          response_headers: [{String.t(), String.t()}],
          response_body: String.t() | nil,
          facts: map() | nil,
          error: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{exchanges: [], secrets: [], next_id: 1} end)

  @doc "Registers a value to redact from everything recorded from now on, and from what is already stored."
  @spec add_secret(pid(), String.t() | nil) :: :ok
  def add_secret(_pid, nil), do: :ok
  def add_secret(_pid, secret) when byte_size(secret) < 6, do: :ok

  def add_secret(pid, secret) do
    Agent.update(pid, fn state ->
      secrets = Enum.uniq([secret | state.secrets])

      %{
        state
        | secrets: secrets,
          exchanges: Enum.map(state.exchanges, &redact_exchange(&1, [secret]))
      }
    end)
  end

  @doc "Records an exchange; returns its id."
  @spec record(pid(), map()) :: pos_integer()
  def record(pid, exchange) do
    Agent.get_and_update(pid, fn state ->
      id = state.next_id
      stored = exchange |> Map.put(:id, id) |> truncate() |> redact_exchange(state.secrets)
      {id, %{state | exchanges: [stored | state.exchanges], next_id: id + 1}}
    end)
  end

  @doc "All exchanges, oldest first."
  @spec exchanges(pid()) :: [exchange()]
  def exchanges(pid), do: Agent.get(pid, &Enum.reverse(&1.exchanges))

  @doc "Redacts registered secrets from an arbitrary string, for messages built outside the transcript."
  @spec redact(pid(), String.t()) :: String.t()
  def redact(pid, text), do: Agent.get(pid, &redact_string(text, &1.secrets))

  defp truncate(exchange) do
    exchange
    |> Map.update(:request_body, nil, &truncate_body/1)
    |> Map.update(:response_body, nil, &truncate_body/1)
  end

  defp truncate_body(body) when is_binary(body) and byte_size(body) > @max_body_bytes,
    do: binary_part(body, 0, @max_body_bytes) <> "…[truncated]"

  defp truncate_body(body), do: body

  defp redact_exchange(exchange, secrets) do
    exchange
    |> Map.update(:url, nil, &redact_string(&1, secrets))
    |> Map.update(:request_body, nil, &redact_string(&1, secrets))
    |> Map.update(:response_body, nil, &redact_string(&1, secrets))
    |> Map.update(:error, nil, &redact_string(&1, secrets))
    |> Map.update(:request_headers, [], fn headers ->
      Enum.map(headers, &redact_header(&1, secrets))
    end)
  end

  defp redact_header({name, _value}, _secrets) when name in ["authorization"],
    do: {name, "Bearer [redacted]"}

  defp redact_header({name, value}, secrets), do: {name, redact_string(value, secrets)}

  defp redact_string(nil, _secrets), do: nil

  defp redact_string(text, secrets) when is_binary(text) do
    Enum.reduce(secrets, text, fn secret, acc -> String.replace(acc, secret, "[redacted]") end)
  end
end
