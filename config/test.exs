import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hcp_conformance, HcpConformanceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pg/6hoSafBkgedMsdzT+iYD5DzuduJZfJKhYaScmnDgPLv5nm5oFxU+D7VceMCjo",
  # Served, so the suite can run end to end against the reference
  # implementation mounted at /reference.
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

config :hcp_conformance, allow_private_targets: true

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
