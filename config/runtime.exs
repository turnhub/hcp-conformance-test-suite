import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hcp_conformance start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hcp_conformance, HcpConformanceWeb.Endpoint, server: true
end

config :hcp_conformance, HcpConformanceWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Runner settings from the environment, where set (see config/config.exs).
if config_env() != :test do
  truthy? = &(&1 in ["1", "true", "TRUE", "yes"])

  env = fn name, parse ->
    with value when is_binary(value) <- System.get_env(name), do: parse.(value)
  end

  settings =
    [
      allow_private_targets: env.("ALLOW_PRIVATE_TARGETS", truthy?),
      max_concurrent_runs: env.("MAX_CONCURRENT_RUNS", &String.to_integer/1),
      basic_auth: env.("UI_BASIC_AUTH", & &1),
      reference_server: env.("REFERENCE_SERVER", truthy?),
      reference_hook_secret: env.("REFERENCE_HOOK_SECRET", & &1),
      openai_base_url: env.("OPENAI_BASE_URL", & &1)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)

  config :hcp_conformance, settings
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :hcp_conformance, HcpConformanceWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/hcp_conformance_web/router\.ex$",
        ~r"lib/hcp_conformance_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # The secret key base signs and encrypts cookies. It is needed to serve (it signs and encrypts the session cookie), not for a CLI
  # run through bin/conformance, which loads this file too.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      if System.get_env("PHX_SERVER") do
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
      end

  host = System.get_env("PHX_HOST") || "example.com"

  bind_address =
    case System.get_env("BIND_ADDRESS") do
      nil ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      address ->
        {:ok, ip} = address |> String.to_charlist() |> :inet.parse_address()
        ip
    end

  config :hcp_conformance, HcpConformanceWeb.Endpoint,
    # The public URL: links, the LiveView origin check, and the base URL the
    # reference implementation advertises. Behind a TLS proxy the defaults fit;
    # a plain-http run sets PHX_URL_SCHEME=http and PHX_URL_PORT.
    url: [
      host: host,
      port: String.to_integer(System.get_env("PHX_URL_PORT", "443")),
      scheme: System.get_env("PHX_URL_SCHEME", "https")
    ],
    http: [
      # All interfaces, IPv6 included (Fly.io needs it). Hosts without IPv6
      # set BIND_ADDRESS=0.0.0.0.
      ip: bind_address
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :hcp_conformance, HcpConformanceWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :hcp_conformance, HcpConformanceWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
