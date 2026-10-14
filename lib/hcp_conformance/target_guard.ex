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

  alias HcpConformance.Settings

  # The IPv4 blocks outside the public internet, as {network, prefix length}:
  # "this" network, private (RFC 1918), shared CGNAT space, loopback, link-local,
  # benchmarking, and multicast plus reserved.
  @private_ipv4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{224, 0, 0, 0}, 3}
  ]

  @doc """
  `:ok` when the URL may be fetched. With private targets refused, the one
  loopback address allowed is this instance's own reference implementation
  (`own_reference`): it holds only synthetic data, and reaching it on loopback
  keeps a proxy or login in front of the public URL out of the way.
  """
  @spec check(String.t(), boolean(), String.t() | nil) :: :ok | {:error, String.t()}
  def check(url, allow_private, own_reference \\ Settings.local_reference_url())

  def check(_url, true = _allow_private, _own_reference), do: :ok

  def check(url, false, own_reference) do
    if own_reference?(url, own_reference), do: :ok, else: check_public(url)
  end

  # Same scheme, host and port as the reference, and a path inside its mount.
  @spec own_reference?(String.t(), String.t() | nil) :: boolean()
  defp own_reference?(_url, nil), do: false

  defp own_reference?(url, own_reference) do
    %URI{scheme: scheme, host: host, port: port, path: mount} = URI.parse(own_reference)

    case URI.parse(url) do
      %URI{scheme: ^scheme, host: ^host, port: ^port, path: path} when is_binary(path) ->
        (path == mount or String.starts_with?(path, mount <> "/")) and
          ".." not in String.split(path, "/")

      _other ->
        false
    end
  end

  @spec check_public(String.t()) :: :ok | {:error, String.t()}
  defp check_public(url) do
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
  def private?({_, _, _, _} = address) do
    Enum.any?(@private_ipv4, fn {network, bits} ->
      prefix(address, bits) == prefix(network, bits)
    end)
  end

  def private?({0, 0, 0, 0, 0, 0, 0, _last} = _loopback_or_unspecified), do: true

  def private?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})

  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFF00) == 0xFF00, do: true
  def private?(_address), do: false

  @spec prefix(:inet.ip4_address(), 0..32) :: non_neg_integer()
  defp prefix({a, b, c, d}, bits), do: (a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d) >>> (32 - bits)
end
