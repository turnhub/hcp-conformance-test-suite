defmodule HcpConformance.TargetGuard do
  @moduledoc """
  Keeps a hosted suite from being used to reach private networks (SSRF). A public
  deployment fetches whatever URL a visitor types in, so by default it refuses
  hosts that resolve to loopback, private, link-local or other non-public
  addresses. Self-hosted and local runs turn the guard off with
  `allow_private_targets`.

  The check resolves the name before each request. It does not pin the resolved
  address for the connection, so DNS rebinding is not fully closed; a deployment
  that must be strict should also run without access to internal networks.
  """

  import Bitwise

  @spec check(String.t(), boolean()) :: :ok | {:error, String.t()}
  def check(_url, true = _allow_private), do: :ok

  def check(url, false) do
    with %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url),
         {:ok, addresses} <- resolve(host) do
      case Enum.find(addresses, &private?/1) do
        nil -> :ok
        address -> {:error, "#{host} resolves to a non-public address (#{:inet.ntoa(address)})"}
      end
    else
      %URI{} -> {:error, "only http and https URLs with a host are allowed"}
      {:error, reason} -> {:error, "cannot resolve #{URI.parse(url).host}: #{inspect(reason)}"}
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        v4 =
          case :inet.getaddrs(charlist, :inet),
            do: (
              {:ok, list} -> list
              _ -> []
            )

        v6 =
          case :inet.getaddrs(charlist, :inet6),
            do: (
              {:ok, list} -> list
              _ -> []
            )

        case v4 ++ v6 do
          [] -> {:error, :nxdomain}
          addresses -> {:ok, addresses}
        end
    end
  end

  @doc "Whether an address is outside the public internet."
  @spec private?(:inet.ip_address()) :: boolean()
  def private?({a, b, _c, _d}) do
    a == 0 or a == 10 or a == 127 or (a == 100 and (b &&& 0xC0) == 64) or (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or (a == 192 and b == 168) or (a == 198 and b in 18..19) or
      a >= 224
  end

  def private?({0, 0, 0, 0, 0, 0, 0, _last} = _loopback_or_unspecified), do: true

  def private?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})

  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFF00) == 0xFF00, do: true
  def private?(_address), do: false
end
