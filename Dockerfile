# Builds the hosted runner and CLI as one image.
#
#   docker build -t hcp-conformance .
#   docker run -p 4000:4000 hcp-conformance                     # the web runner on :4000
#   docker run --rm hcp-conformance bin/conformance --target …  # one CLI run
#
# Configuration is environment variables; see README.md.

ARG ELIXIR_IMAGE=elixir:1.18
ARG RUNTIME_IMAGE=debian:trixie-slim

FROM ${ELIXIR_IMAGE} AS build
ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY config config
COPY lib lib
COPY docs docs
COPY rel rel
RUN mix compile && mix release

FROM ${RUNTIME_IMAGE}
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
  && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 SERVE=true PORT=4000
WORKDIR /app
COPY --from=build --chown=nobody:nogroup /app/_build/prod/rel/hcp_conformance ./
USER nobody
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=3s CMD ["sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT} && printf 'GET /health HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q ok <&3"]
CMD ["bin/hcp_conformance", "start"]
