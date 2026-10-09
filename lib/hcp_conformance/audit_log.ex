defmodule HcpConformance.AuditLog do
  @moduledoc """
  Reads the person's audit log (§4.3) and waits for events to appear.

  Events other than `preference.read` must be durable before the operation is
  acknowledged; `preference.read` may trail by the window the target declares
  (§4.3.4). `await/4` polls up to that window plus a grace period, so a target is
  held to what it declared rather than to an arbitrary timeout.
  """

  alias HcpConformance.{Assert, Context}

  @grace_ms 3_000
  @max_pages 50

  @doc "Every event in the log, oldest first, following cursors."
  @spec fetch!(Context.t()) :: [map()]
  def fetch!(ctx) do
    token = Context.person!(ctx)
    fetch_pages(ctx, token, nil, [], 0)
  end

  defp fetch_pages(_ctx, _token, _cursor, acc, @max_pages), do: acc

  defp fetch_pages(ctx, token, cursor, acc, page) do
    params = if cursor, do: [limit: 200, cursor: cursor], else: [limit: 200]
    response = Context.request(ctx, :get, Context.url(ctx, :audit), token: token, params: params)
    Assert.status!(response, 200, "GET /v1/audit")
    body = Assert.json_object!(response, "GET /v1/audit")
    events = body["events"]
    Assert.check!(is_list(events), "GET /v1/audit: the body has no events array")

    case body["nextCursor"] do
      next when is_binary(next) and next != "" and events != [] ->
        fetch_pages(ctx, token, next, acc ++ events, page + 1)

      _done ->
        acc ++ events
    end
  end

  @doc """
  Waits until at least one event satisfies `match`, and returns the matches.
  `read?: true` allows the declared `preference.read` durability window.
  """
  @spec await!(Context.t(), String.t(), (map() -> boolean()), keyword()) :: [map(), ...]
  def await!(ctx, label, match, opts \\ []) do
    window = if Keyword.get(opts, :read?, false), do: ctx.read_window_ms, else: 0
    deadline = System.monotonic_time(:millisecond) + window + @grace_ms
    poll(ctx, label, match, deadline, window)
  end

  defp poll(ctx, label, match, deadline, window) do
    case Enum.filter(fetch!(ctx), match) do
      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          Assert.fail!(
            "no #{label} event appeared in the audit log within #{window + @grace_ms} ms " <>
              "(declared durability window #{window} ms plus #{@grace_ms} ms grace)"
          )
        else
          Process.sleep(500)
          poll(ctx, label, match, deadline, window)
        end

      matches ->
        matches
    end
  end

  @doc "Event matcher on type and optional fields."
  @spec event?(map(), String.t(), keyword()) :: boolean()
  def event?(event, type, fields \\ []) do
    event["eventType"] == type and
      Enum.all?(fields, fn {key, value} -> event[Atom.to_string(key)] == value end)
  end
end
