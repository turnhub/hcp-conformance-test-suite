defmodule HcpConformance.TargetGuard do
  @moduledoc """
  Keeps a hosted suite from being used to reach private networks (SSRF). A public
  deployment fetches whatever URL a visitor types in, so by default it refuses
  hosts that resolve to loopback, private, link-local or other non-public
  addresses. Self-hosted and local runs turn the guard off with
  `allow_private_targets`.

  The check resolves the name once and hands back the address it vetted; the
  HTTP client connects to that address, never to the name again. A resolver that
  changes its answer between the check and the connection (DNS rebinding) gains
  nothing. A name with several answers is refused if any of them is private.

  The message a visitor sees never includes the address a name resolved to: on a
  split-horizon network that would make the guard an oracle for internal DNS.
  """

  import Bitwise

  require Logger

  alias HcpConformance.Settings

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address(), ...]} | {:error, term()})

  # The IPv4 blocks outside the public internet, as {network, prefix length}:
  # "this" network, private (RFC 1918), shared CGNAT space, loopback, link-local,
  # IETF protocol assignments, documentation (TEST-NET-1..3), benchmarking, and
  # multicast plus reserved.
  @private_ipv4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3}
  ]

  @doc """
  `{:ok, address}` when the URL may be fetched, with the address the connection
  must go to. With private targets refused, the one loopback address allowed is
  this instance's own reference implementation (`own_reference`): it holds only
  synthetic data, and reaching it on loopback keeps a proxy or login in front of
  the public URL out of the way.

  `opts[:resolver]` replaces DNS, for tests.
  """
  @spec check(String.t(), boolean(), String.t() | nil, resolver: resolver()) ::
          {:ok, :inet.ip_address()} | {:error, String.t()}
  def check(url, allow_private, own_reference \\ Settings.local_reference_url(), opts \\ []) do
    resolver = Keyword.get(opts, :resolver, &resolve/1)

    with {:ok, host, addresses} <- resolve_url(url, resolver) do
      cond do
        allow_private or own_reference?(url, own_reference) ->
          {:ok, pick(addresses)}

        Enum.any?(addresses, &private?/1) ->
          Logger.info("target guard refused #{host}: resolves to #{inspect(addresses)}")
          {:error, "#{host} resolves to a non-public address"}

        true ->
          {:ok, pick(addresses)}
      end
    end
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

  @spec resolve_url(String.t(), resolver()) ::
          {:ok, String.t(), [:inet.ip_address(), ...]} | {:error, String.t()}
  defp resolve_url(url, resolver) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        case resolver.(host) do
          {:ok, [_address | _rest] = addresses} -> {:ok, host, addresses}
          {:ok, []} -> {:error, "cannot resolve #{host}: :nxdomain"}
          {:error, reason} -> {:error, "cannot resolve #{host}: #{inspect(reason)}"}
        end

      _other ->
        {:error, "only http and https URLs with a host are allowed"}
    end
  end

  # IPv4 first: the host that serves both is reachable on either, and an IPv4
  # pin needs nothing of the local network's IPv6.
  @spec pick([:inet.ip_address(), ...]) :: :inet.ip_address()
  defp pick(addresses) do
    Enum.find(addresses, hd(addresses), &(tuple_size(&1) == 4))
  end

  @doc "The addresses a host name (or address literal) stands for."
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address(), ...]} | {:error, term()}
  def resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        case lookup(charlist, :inet) ++ lookup(charlist, :inet6) do
          [] -> {:error, :nxdomain}
          addresses -> {:ok, addresses}
        end
    end
  end

  @spec lookup(charlist(), :inet | :inet6) :: [:inet.ip_address()]
  defp lookup(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  @doc "Whether an address is outside the public internet."
  @spec private?(:inet.ip_address()) :: boolean()
  def private?({_, _, _, _} = address) do
    Enum.any?(@private_ipv4, fn {network, bits} ->
      prefix(address, bits) == prefix(network, bits)
    end)
  end

  # ::/96: unspecified, loopback and the deprecated IPv4-compatible form.
  def private?({0, 0, 0, 0, 0, 0, _high, _low}), do: true

  # IPv4-mapped (::ffff:a.b.c.d), NAT64 (64:ff9b::/96) and 6to4 (2002::/16) carry
  # an IPv4 address: they are as private as it is.
  def private?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: private?(embedded(high, low))
  def private?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: private?(embedded(high, low))
  def private?({0x2002, high, low, _, _, _, _, _}), do: private?(embedded(high, low))

  # Teredo (2001::/32) carries the client's IPv4 address, inverted, in the last
  # 32 bits.
  def private?({0x2001, 0, _, _, _, _, high, low}),
    do: private?(embedded(bxor(high, 0xFFFF), bxor(low, 0xFFFF)))

  # Local-use NAT64 (64:ff9b:1::/48) and documentation (2001:db8::/32).
  def private?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true
  def private?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true

  # Unique local (fc00::/7), link-local (fe80::/10) and multicast (ff00::/8).
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFF00) == 0xFF00, do: true
  def private?(_address), do: false

  @spec embedded(0..0xFFFF, 0..0xFFFF) :: :inet.ip4_address()
  defp embedded(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  @spec prefix(:inet.ip4_address(), 0..32) :: non_neg_integer()
  defp prefix({a, b, c, d}, bits), do: (a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d) >>> (32 - bits)
end
