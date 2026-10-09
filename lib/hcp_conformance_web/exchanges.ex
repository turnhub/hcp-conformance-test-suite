defmodule HcpConformanceWeb.Exchanges do
  @moduledoc """
  HTTP exchanges as the run and chat pages show them: method, path, status and
  time, expanding to the request and response headers and bodies. They come
  from a transcript, so credentials are already redacted.
  """

  use HcpConformanceWeb, :html

  # Characters of each body shown on a page; the JSON report keeps up to 16 KB.
  @body_chars 8_000

  attr :row, :string,
    required: true,
    doc: "the DOM id of the row it shows in; one exchange can show in several"

  attr :exchange, :map, required: true

  @doc "One HTTP exchange, collapsed to its method, path, status and time."
  def exchange(assigns) do
    ~H"""
    <details id={"#{@row}-exchange-#{@exchange.id}"} class="collapse collapse-arrow bg-base-100">
      <summary class="collapse-title">
        <span class={["badge", exchange_class(@exchange)]}>{@exchange.status || "ERR"}</span>
        <code>{@exchange.method} {@exchange.path}</code>
        <span :if={@exchange.kind == :hook} class="badge badge-ghost">hook</span>
        <span>{@exchange.duration_ms} ms</span>
      </summary>
      <div class="collapse-content">
        <.list>
          <:item title="URL"><code>{@exchange.url}</code></:item>
          <:item title="Request headers">
            <pre class="whitespace-pre-wrap">{@exchange.request_headers}</pre>
          </:item>
          <:item :if={@exchange.request_body} title="Request body">
            <pre class="whitespace-pre-wrap">{@exchange.request_body}</pre>
          </:item>
          <:item title="Response headers">
            <pre class="whitespace-pre-wrap">{@exchange.response_headers}</pre>
          </:item>
          <:item title={if @exchange.error, do: "Error", else: "Response body"}>
            <pre class="whitespace-pre-wrap">{@exchange.error || @exchange.response_body}</pre>
          </:item>
        </.list>
      </div>
    </details>
    """
  end

  @doc """
  An exchange as a page shows it: headers as lines, JSON bodies pretty-printed,
  long bodies cut (a downloaded report holds more).
  """
  @spec entry(map()) :: map()
  def entry(exchange) do
    uri = URI.parse(exchange.url)

    %{
      id: exchange.id,
      kind: exchange.kind,
      check_id: exchange.check_id,
      method: exchange.method,
      url: exchange.url,
      path: (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: ""),
      status: exchange.status,
      duration_ms: exchange.duration_ms,
      error: exchange.error,
      request_headers: header_lines(exchange.request_headers),
      request_body: display_body(exchange.request_body),
      response_headers: header_lines(exchange.response_headers),
      response_body: display_body(exchange.response_body)
    }
  end

  defp header_lines([]), do: "(none)"

  defp header_lines(headers),
    do: Enum.map_join(headers, "\n", fn [name, value] -> "#{name}: #{value}" end)

  defp display_body(nil), do: nil
  defp display_body(""), do: nil

  defp display_body(body) do
    pretty =
      case Jason.decode(body) do
        {:ok, _json} -> Jason.Formatter.pretty_print(body)
        {:error, _reason} -> body
      end

    if String.length(pretty) > @body_chars do
      String.slice(pretty, 0, @body_chars) <>
        "\n…[cut here; the JSON report holds more]"
    else
      pretty
    end
  end

  defp exchange_class(%{status: status}) when status in 200..299, do: "badge-success"
  defp exchange_class(%{status: status}) when status in 300..499, do: "badge-info"
  defp exchange_class(_exchange), do: "badge-error"
end
