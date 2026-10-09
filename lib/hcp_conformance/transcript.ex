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

  @doc """
  Starts a transcript. `on_exchange` is called with each exchange as it is
  recorded, already redacted, in the process that made the request: the live
  HTTP log in the UI is fed from it.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    listener = Keyword.get(opts, :on_exchange)
    Agent.start_link(fn -> %{exchanges: [], secrets: [], next_id: 1, listener: listener} end)
  end

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

  @doc """
  Records an exchange, redacted with every secret registered so far, and hands it
  to the listener. Returns the stored exchange. Register secrets that arrive in a
  response (`HcpConformance.HTTP`'s `secret_fields`) before recording it, or the
  listener sees them.
  """
  @spec record(pid(), map()) :: exchange()
  def record(pid, exchange) do
    {stored, listener} =
      Agent.get_and_update(pid, fn state ->
        id = state.next_id
        stored = exchange |> Map.put(:id, id) |> truncate() |> redact_exchange(state.secrets)

        {{stored, state.listener},
         %{state | exchanges: [stored | state.exchanges], next_id: id + 1}}
      end)

    if listener, do: listener.(stored)
    stored
  end

  @doc "An exchange as plain JSON-encodable data: headers become `[name, value]` pairs."
  @spec serializable(exchange()) :: map()
  def serializable(exchange) do
    exchange
    |> Map.update!(:request_headers, &Enum.map(&1, fn {name, value} -> [name, value] end))
    |> Map.update!(:response_headers, &Enum.map(&1, fn {name, value} -> [name, value] end))
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

  # Bodies end up in JSON (the report, the live log), so they must stay valid
  # UTF-8: a cut lands on a character boundary, and a body that is not text at
  # all is replaced by a note.
  defp truncate_body(nil), do: nil

  defp truncate_body(body) when byte_size(body) > @max_body_bytes do
    case :unicode.characters_to_binary(binary_part(body, 0, @max_body_bytes)) do
      text when is_binary(text) -> text <> "…[truncated]"
      {:incomplete, text, _rest} -> text <> "…[truncated]"
      {:error, _text, _rest} -> binary_note(body)
    end
  end

  defp truncate_body(body), do: if(String.valid?(body), do: body, else: binary_note(body))

  defp binary_note(body), do: "[binary body, #{byte_size(body)} bytes]"

  defp redact_exchange(exchange, secrets) do
    exchange
    |> Map.update(:url, nil, &redact_string(&1, secrets))
    |> Map.update(:request_body, nil, &redact_string(&1, secrets))
    |> Map.update(:response_body, nil, &redact_string(&1, secrets))
    |> Map.update(:error, nil, &redact_string(&1, secrets))
    |> Map.update(:request_headers, [], fn headers ->
      Enum.map(headers, &redact_header(&1, secrets))
    end)
    |> Map.update(:response_headers, [], fn headers ->
      Enum.map(headers, &redact_header(&1, secrets))
    end)
  end

  # Credentials travel in headers too: the suite's bearer, and any session a
  # target hands back.
  defp redact_header({"authorization", _value}, _secrets),
    do: {"authorization", "Bearer [redacted]"}

  defp redact_header({name, _value}, _secrets)
       when name in ["proxy-authorization", "cookie", "set-cookie"],
       do: {name, "[redacted]"}

  defp redact_header({name, value}, secrets), do: {name, redact_string(value, secrets)}

  defp redact_string(nil, _secrets), do: nil

  defp redact_string(text, secrets) when is_binary(text) do
    Enum.reduce(secrets, text, fn secret, acc -> String.replace(acc, secret, "[redacted]") end)
  end
end
