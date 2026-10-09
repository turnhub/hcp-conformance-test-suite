defmodule HcpConformance.Settings do
  @moduledoc """
  The deployment's runner settings: defaults in config/config.exs, overridden
  from the environment in config/runtime.exs. They belong to whoever runs the
  instance, never to a visitor: a submitted run cannot turn the private-network
  guard off.
  """

  @spec allow_private_targets?() :: boolean()
  def allow_private_targets?, do: get(:allow_private_targets, false) == true

  @spec max_concurrent_runs() :: non_neg_integer()
  def max_concurrent_runs, do: get(:max_concurrent_runs, 4)

  @doc "`\"user:password\"` when the runner is behind basic auth, else nil."
  @spec basic_auth() :: String.t() | nil
  def basic_auth do
    case get(:basic_auth, nil) do
      credentials when is_binary(credentials) and credentials != "" -> credentials
      _unset -> nil
    end
  end

  @spec reference_server?() :: boolean()
  def reference_server?, do: get(:reference_server, true) == true

  @spec reference_hook_secret() :: String.t()
  def reference_hook_secret, do: get(:reference_hook_secret, "reference-hook-secret")

  defp get(key, default), do: Application.get_env(:hcp_conformance, key, default)
end
