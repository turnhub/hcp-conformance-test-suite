defmodule HcpConformance.HTTP do
  @moduledoc """
  The suite's only way to reach a target. Records every exchange in the run's
  transcript, tagged with the check that made it, and applies the private-network
  guard before each request.

  Bodies are not decoded by the HTTP client: the suite parses JSON itself so a
  malformed body is a finding about the target rather than a crash.
  """

  alias HcpConformance.{TargetGuard, Transcript}

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
          timeout: pos_integer()
        ]

  @doc """
  Sends a request. `transcript` is the run's transcript; `allow_private` turns the
  network guard off.
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

    with :ok <- TargetGuard.check(url, allow_private),
         {:ok, response} <- send_request(method, url, headers, body, opts) do
      response_headers = flatten_headers(response.headers)
      raw = IO.iodata_to_binary(response.body || "")
      json = decode(raw)

      id =
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

  defp send_request(method, url, headers, body, opts) do
    Req.request(
      method: method,
      url: url,
      headers: headers,
      body: body,
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      receive_timeout: Keyword.get(opts, :timeout, 15_000),
      connect_options: [timeout: 10_000]
    )
  end

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

  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {name, values} ->
      Enum.map(List.wrap(values), &{String.downcase(name), &1})
    end)
  end

  defp flatten_headers(headers) when is_list(headers),
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
