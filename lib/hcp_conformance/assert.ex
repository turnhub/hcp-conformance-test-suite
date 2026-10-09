defmodule HcpConformance.Assert do
  @moduledoc """
  Assertions for checks. Each raises `HcpConformance.Failure` with a message that
  names what the specification expects and what the target did, so a report reads
  without the code.
  """

  alias HcpConformance.{Failure, HTTP.Response, Skip, Transcript}

  @spec fail!(String.t()) :: no_return()
  def fail!(message), do: raise(Failure, message: message)

  @spec not_applicable!(String.t()) :: no_return()
  def not_applicable!(message), do: raise(HcpConformance.NotApplicable, message: message)

  @spec skip!(String.t()) :: no_return()
  def skip!(message), do: raise(Skip, message: message)

  @spec check!(as_boolean(term()), String.t()) :: :ok
  def check!(condition, message) do
    if condition, do: :ok, else: fail!(message)
  end

  @doc "The response status is one of `expected` (an integer or a list)."
  @spec status!(Response.t(), integer() | [integer()], String.t()) :: Response.t()
  def status!(%Response{status: status} = response, expected, what) do
    expected = List.wrap(expected)

    if status in expected do
      response
    else
      fail!(
        "#{what}: expected HTTP #{Enum.join(expected, " or ")}, got #{status}#{body_hint(response)}"
      )
    end
  end

  @doc "The response is a JSON object; returns it."
  @spec json_object!(Response.t(), String.t()) :: map()
  def json_object!(%Response{json: json} = response, what) do
    if is_map(json) do
      json
    else
      fail!("#{what}: expected a JSON object body#{body_hint(response)}")
    end
  end

  @doc """
  The response is an RFC 9457 problem with the given status and registered HCP
  problem type slug (§3.4.4).
  """
  @spec problem!(Response.t(), integer(), String.t(), String.t()) :: map()
  def problem!(response, status, slug, what) do
    status!(response, status, what)
    body = json_object!(response, what)
    type = body["type"]

    check!(
      is_binary(type) and String.ends_with?(type, "/" <> slug),
      "#{what}: expected problem type ending in \"#{slug}\", got #{inspect(type)}"
    )

    body
  end

  @doc "A 4xx refusal, for requirements that say a request is refused without fixing the status."
  @spec refused!(Response.t(), String.t()) :: Response.t()
  def refused!(%Response{status: status} = response, what) do
    if status in 400..499 do
      response
    else
      fail!(
        "#{what}: expected the request to be refused with a 4xx status, got #{status}#{body_hint(response)}"
      )
    end
  end

  @spec body_hint(Response.t()) :: String.t()
  def body_hint(%Response{body: body}) when is_binary(body) and body != "" do
    " (body: " <> Transcript.excerpt(body, 300) <> ")"
  end

  def body_hint(_response), do: ""
end
