defmodule HcpConformance.Config do
  @moduledoc """
  What a run targets and how it authenticates.

  Three modes, picked from what is supplied:

  - **hook**: `hook_url` and `hook_secret`. The suite creates a fresh subject and
    issues the grants each check needs through the conformance hook
    (docs/HOOK.md). Every check can run.
  - **static**: `person_token`, optionally `agent_token`. The suite works inside an
    existing subject. Checks that need grants created on demand are skipped.
  - **anonymous**: no credentials. Only the discovery document and the
    unauthenticated transport checks run.
  """

  @enforce_keys [:target]
  defstruct [
    :target,
    :discovery_url,
    :hook_url,
    :hook_secret,
    :person_token,
    :agent_token,
    :subject_did,
    :category,
    groups: nil,
    only: nil,
    allow_private: false,
    check_timeout_ms: 60_000,
    label: nil
  ]

  @type t :: %__MODULE__{}
  @type mode :: :hook | :static | :anonymous

  @doc "Builds a config from a map or keyword list with string or atom keys."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), blank_to_nil(value)} end)

    config = %__MODULE__{
      target: trim_slash(attrs["target"]),
      discovery_url: attrs["discovery_url"],
      hook_url: trim_slash(attrs["hook_url"]),
      hook_secret: attrs["hook_secret"],
      person_token: attrs["person_token"],
      agent_token: attrs["agent_token"],
      subject_did: attrs["subject_did"],
      category: attrs["category"],
      groups: list(attrs["groups"]),
      only: list(attrs["only"]),
      allow_private: attrs["allow_private"] in [true, "true", "1"],
      check_timeout_ms: integer(attrs["check_timeout_ms"], 60_000),
      label: attrs["label"]
    }

    validate(config)
  end

  @doc "Which authentication mode a config runs in."
  @spec mode(t()) :: mode()
  def mode(%__MODULE__{hook_url: hook, hook_secret: secret})
      when is_binary(hook) and is_binary(secret),
      do: :hook

  def mode(%__MODULE__{person_token: token}) when is_binary(token), do: :static
  def mode(_config), do: :anonymous

  @doc "The config with every credential removed, safe to store and show."
  @spec public(t()) :: map()
  def public(config) do
    %{
      target: config.target,
      discovery_url: config.discovery_url,
      hook_url: config.hook_url,
      mode: mode(config),
      category: config.category,
      groups: config.groups,
      only: config.only,
      label: config.label,
      agent_token_supplied: is_binary(config.agent_token)
    }
  end

  defp validate(%__MODULE__{target: nil, discovery_url: nil}),
    do: {:error, "target (the HCP base URL) or discovery_url is required"}

  defp validate(config) do
    urls = Enum.reject([config.target, config.discovery_url, config.hook_url], &is_nil/1)

    cond do
      Enum.any?(urls, &(not http_url?(&1))) ->
        {:error, "URLs must be absolute http or https URLs"}

      is_binary(config.hook_url) and is_nil(config.hook_secret) ->
        {:error, "hook_secret is required with hook_url"}

      true ->
        {:ok, %{config | target: config.target || base_from_discovery(config.discovery_url)}}
    end
  end

  defp base_from_discovery(url),
    do: String.replace(url, ~r{/\.well-known/hcp-configuration/?$}, "")

  defp http_url?(url) do
    match?(
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "",
      URI.parse(url)
    )
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp trim_slash(nil), do: nil
  defp trim_slash(url), do: String.trim_trailing(url, "/")

  defp list(nil), do: nil
  defp list(value) when is_list(value), do: value

  defp list(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp integer(nil, default), do: default
  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _invalid -> default
    end
  end

  defp integer(_value, default), do: default
end
