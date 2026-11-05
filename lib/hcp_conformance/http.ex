defmodule HcpConformance.HTTP do
  @moduledoc """
  The suite's only way to reach a target. Records every exchange in the run's
  transcript, tagged with the check that made it, and applies the private-network
  guard before each request.

  Bodies are not decoded by the HTTP client: the suite parses JSON itself so a
  malformed body is a finding about the target rather than a crash.

  The connection goes to the address the guard vetted, not to the host name: the
  name is resolved once, so a DNS answer that changes between the check and the
  connection (rebinding) cannot redirect a request onto a private network. The
  name still serves as the `Host` header, for SNI and for certificate
  verification. Mint is driven directly for that: a pooled client resolves the
  name itself, and a pool per target would leak one for every name a visitor
  submits. No connection outlives its request. Redirects are never followed.
  """

  alias HcpConformance.{TargetGuard, Transcript}

  @connect_timeout 10_000
  @receive_timeout 15_000

  defmodule Response do
    @moduledoc "A response as checks see it."
    defstruct [:status, :headers, :body, :json, :content_type, :exchange_id]

    @type t :: %__MODULE__{
            status: integer(),
            headers: [{String.t(), String.t()}],
            body: String.t(),
            json: term(),
            content_type: String.t() | nil,
            exchange_id: pos_integer()
          }

    @doc "A response header, by lowercase name."
    @spec header(t(), String.t()) :: String.t() | nil
    def header(%__MODULE__{headers: headers}, name) do
      Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
    end
  end

  defmodule TransportError do
    @moduledoc "The target could not be reached, or the guard refused it."
    defexception [:message]
  end

  @type opts :: [
          token: String.t() | nil,
          json: term(),
          params: keyword() | map(),
          headers: [{String.t(), String.t()}],
          kind: :target | :hook,
          timeout: pos_integer(),
          secret_fields: [String.t()],
          resolver: TargetGuard.resolver()
        ]

  @doc """
  Sends a request. `transcript` is the run's transcript; `allow_private` turns the
  network guard off. `opts[:resolver]` replaces DNS, for tests.
  """
  @spec request(pid(), boolean(), atom(), String.t(), opts()) :: Response.t()
  def request(transcript, allow_private, method, url, opts \\ []) do
    url = with_params(url, opts[:params])
    body = if Keyword.has_key?(opts, :json), do: Jason.encode!(opts[:json]), else: nil
    headers = build_headers(opts, body)
    method_name = method |> Atom.to_string() |> String.upcase()
    started = System.monotonic_time(:millisecond)

    exchange = %{
      check_id: Process.get(:hcp_check_id),
      kind: Keyword.get(opts, :kind, :target),
      method: method_name,
      url: url,
      request_headers: headers,
      request_body: body
    }

    with {:ok, address} <-
           TargetGuard.check(url, allow_private, own_reference(), guard_opts(opts)),
         {:ok, response} <- send_request(method_name, url, address, headers, body, opts) do
      response_headers = flatten_headers(response.headers)
      raw = IO.iodata_to_binary(response.body)
      json = decode(raw)
      register_secrets(transcript, json, Keyword.get(opts, :secret_fields, []))

      %{id: id} =
        Transcript.record(
          transcript,
          Map.merge(exchange, %{
            status: response.status,
            response_headers: response_headers,
            response_body: raw,
            facts: facts(json),
            error: nil,
            duration_ms: System.monotonic_time(:millisecond) - started
          })
        )

      %Response{
        status: response.status,
        headers: response_headers,
        body: raw,
        json: json,
        content_type: content_type(response_headers),
        exchange_id: id
      }
    else
      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: Exception.message(reason)

        Transcript.record(
          transcript,
          Map.merge(exchange, %{
            status: nil,
            response_headers: [],
            response_body: nil,
            facts: nil,
            error: message,
            duration_ms: System.monotonic_time(:millisecond) - started
          })
        )

        raise TransportError,
          message: "#{method_name} #{Transcript.redact(transcript, url)}: #{message}"
    end
  end

  # Credentials a response hands out (a hook's tokens) are secrets from the
  # moment they arrive: registered before the exchange is recorded or streamed.
  defp register_secrets(transcript, %{} = json, fields) do
    for field <- fields, value = json[field], is_binary(value) do
      Transcript.add_secret(transcript, value)
    end

    :ok
  end

  defp register_secrets(_transcript, _json, _fields), do: :ok

  defp own_reference, do: HcpConformance.Settings.local_reference_url()

  defp guard_opts(opts), do: Keyword.take(opts, [:resolver])

  @typep raw_response :: %{
           status: pos_integer(),
           headers: [{String.t(), String.t()}],
           body: iodata()
         }

  # One connection per request, to the vetted address, closed when the response
  # is in. Passive mode keeps the socket's traffic out of the caller's mailbox
  # (a LiveView's async task, say).
  @spec send_request(
          String.t(),
          String.t(),
          :inet.ip_address(),
          [{String.t(), String.t()}],
          String.t() | nil,
          opts()
        ) ::
          {:ok, raw_response()} | {:error, Exception.t()}
  defp send_request(method, url, address, headers, body, opts) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @receive_timeout)

    connect_opts = [
      hostname: uri.host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: [timeout: @connect_timeout] ++ family(address)
    ]

    with {:ok, conn} <- Mint.HTTP.connect(scheme, address, uri.port, connect_opts) do
      exchange =
        with {:ok, conn, ref} <- Mint.HTTP.request(conn, method, target(uri), headers, body || "") do
          receive_response(conn, ref, deadline)
        end

      case exchange do
        {:ok, conn, response} ->
          Mint.HTTP.close(conn)
          {:ok, response}

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason}
      end
    end
  end

  defp family({_, _, _, _, _, _, _, _}), do: [inet6: true]
  defp family({_, _, _, _}), do: []

  defp target(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  @spec receive_response(Mint.HTTP.t(), Mint.Types.request_ref(), integer()) ::
          {:ok, Mint.HTTP.t(), raw_response()} | {:error, Mint.HTTP.t(), Exception.t()}
  defp receive_response(conn, ref, deadline) do
    collect(conn, ref, deadline, %{status: nil, headers: [], body: []})
  end

  defp collect(conn, ref, deadline, acc) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining <= 0 -> {:error, conn, %Mint.TransportError{reason: :timeout}}
      remaining -> collect_received(recv(conn, remaining), ref, deadline, acc)
    end
  end

  defp collect_received({:error, conn, reason}, _ref, _deadline, _acc), do: {:error, conn, reason}

  defp collect_received({:ok, conn, responses}, ref, deadline, acc) do
    case Enum.reduce(responses, {acc, false}, &collect_part(&1, ref, &2)) do
      {acc, true} -> {:ok, conn, finish(acc)}
      {acc, false} -> collect(conn, ref, deadline, acc)
    end
  end

  defp recv(conn, timeout) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} -> {:ok, conn, responses}
      {:error, conn, reason, _responses} -> {:error, conn, reason}
    end
  end

  defp collect_part({:status, ref, status}, ref, {acc, done}), do: {%{acc | status: status}, done}

  defp collect_part({:headers, ref, headers}, ref, {acc, done}),
    do: {%{acc | headers: acc.headers ++ headers}, done}

  defp collect_part({:data, ref, data}, ref, {acc, done}),
    do: {%{acc | body: [acc.body | data]}, done}

  defp collect_part({:done, ref}, ref, {acc, _done}), do: {acc, true}
  defp collect_part(_other, _ref, state), do: state

  defp finish(acc), do: %{acc | body: IO.iodata_to_binary(acc.body)}

  defp build_headers(opts, body) do
    base = [{"accept", "application/ld+json, application/json, application/problem+json"}]
    auth = if opts[:token], do: [{"authorization", "Bearer " <> opts[:token]}], else: []
    content = if body, do: [{"content-type", "application/json"}], else: []
    base ++ auth ++ content ++ Keyword.get(opts, :headers, [])
  end

  defp with_params(url, nil), do: url
  defp with_params(url, params) when params == [] or params == %{}, do: url

  defp with_params(url, params) do
    uri = URI.parse(url)
    existing = if uri.query, do: URI.decode_query(uri.query), else: %{}

    merged =
      Enum.reduce(params, existing, fn {key, value}, acc ->
        Map.put(acc, to_string(key), to_string(value))
      end)

    URI.to_string(%{uri | query: URI.encode_query(merged)})
  end

  defp flatten_headers(headers),
    do: Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)

  defp content_type(headers) do
    Enum.find_value(headers, fn
      {"content-type", value} ->
        value |> String.split(";") |> hd() |> String.trim() |> String.downcase()

      _other ->
        nil
    end)
  end

  # What the run-wide checks need to know about a body, taken before the
  # transcript truncates it: large bodies (a full audit log) would no longer parse.
  defp facts(%{} = body) do
    %{
      object: true,
      hcp_version: body["hcp_version"],
      members: body |> Map.take(["type", "title", "status", "detail"]) |> Map.keys(),
      type: body["type"],
      status: body["status"]
    }
  end

  defp facts(_body), do: %{object: false}

  defp decode(""), do: nil

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end
end
