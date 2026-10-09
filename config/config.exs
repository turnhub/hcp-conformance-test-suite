# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hcp_conformance,
  generators: [timestamp_type: :utc_datetime]

# Runner settings; config/runtime.exs overrides them from the environment.
config :hcp_conformance,
  # Targets on loopback and private networks. Off for anything public: the
  # runner fetches whatever URL a visitor submits.
  allow_private_targets: false,
  max_concurrent_runs: 4,
  # "user:password" puts the runner behind basic auth.
  basic_auth: nil,
  reference_server: true,
  reference_hook_secret: "reference-hook-secret"

# Configure the endpoint
config :hcp_conformance, HcpConformanceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HcpConformanceWeb.ErrorHTML, json: HcpConformanceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HcpConformance.PubSub,
  live_view: [signing_salt: "2gAItiD/"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  hcp_conformance: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  hcp_conformance: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
