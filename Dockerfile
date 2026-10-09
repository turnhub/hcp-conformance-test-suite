# The web runner and the CLI in one image, built as a Phoenix release.
#
#   docker build -t hcp-conformance .
#   docker run -p 4000:4000 -e SECRET_KEY_BASE=… -e PHX_HOST=conformance.example.com hcp-conformance
#   docker run --rm hcp-conformance bin/conformance --target https://vault.example.com …
#
# Configuration is environment variables; see README.md.

ARG ELIXIR_IMAGE=elixir:1.18
ARG RUNNER_IMAGE=debian:trixie-slim

FROM ${ELIXIR_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile
RUN mix assets.setup

COPY priv priv
COPY lib lib
COPY docs docs
# Compile before the assets: colocated hooks are extracted at compile time.
RUN mix compile
COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app
ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/hcp_conformance ./

USER nobody
EXPOSE 4000
CMD ["/app/bin/server"]
