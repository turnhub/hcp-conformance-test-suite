import Config

# Everything a hosted deployment needs comes from the environment, so one image
# runs anywhere (Fly.io, Cloud Run, a VM) without a rebuild.
if config_env() != :test do
  truthy? = fn value -> value in ["1", "true", "TRUE", "yes"] end

  config :hcp_conformance,
    serve: truthy?.(System.get_env("SERVE", if(config_env() == :prod, do: "true", else: "false"))),
    port: String.to_integer(System.get_env("PORT", "4000")),
    # A local runner usually tests something on localhost; a deployed one must not.
    allow_private_targets:
      truthy?.(System.get_env("ALLOW_PRIVATE_TARGETS", if(config_env() == :prod, do: "false", else: "true"))),
    max_concurrent_runs: String.to_integer(System.get_env("MAX_CONCURRENT_RUNS", "4")),
    basic_auth: System.get_env("UI_BASIC_AUTH"),
    reference_server: truthy?.(System.get_env("REFERENCE_SERVER", "true")),
    reference_hook_secret: System.get_env("REFERENCE_HOOK_SECRET", "reference-hook-secret"),
    public_url: System.get_env("PUBLIC_URL")
end
