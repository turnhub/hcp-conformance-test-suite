# Hosting the runner on Cloudflare

The runner is a Phoenix release, so it runs as a [Cloudflare Container](https://developers.cloudflare.com/containers/)
behind a small Worker. This is the same shape as `turnhub/self-triage-dataset`'s `site/`: a
`wrangler.jsonc`, `npm run deploy`, and Workers Builds for deploy on push. The difference is
that the Worker here only fronts the container, rather than serving the app itself.

```
browser ── https ──▶ Worker (src/index.ts) ── http ──▶ Container: the release from ../Dockerfile
                     · http → https redirect               · the runner, the API, /reference
                     · x-forwarded-proto                   · stateless; sleeps after 15 idle minutes
                     · LiveView WebSocket upgrade
```

Containers need the **Workers Paid plan** ($5 a month). The free plan has no container allowance.
One `basic` instance (1/4 vCPU, 1 GiB) serves every request. The app is stateless and
`MAX_CONCURRENT_RUNS` caps the runs it takes at once, so one instance is enough.

## Deploy

### With Workers Builds (no token on your machine)

1. In the Cloudflare dashboard, open **Workers & Pages → Create → Import a repository** and pick
   `turnhub/hcp-conformance-test-suite`.
2. Set **Root directory** to `cloudflare`, **Deploy command** to `npx wrangler deploy`, and the
   production branch to `main`. The Worker name must stay `hcp-conformance`, as in `wrangler.jsonc`.
3. Under the Worker's **Settings → Variables and Secrets**, add the secrets below.
4. Push to `main`. Workers Builds builds the Docker image and rolls it out. The first deploy takes
   a few minutes to provision before the container answers.

### From your machine

Node 22 and Docker running:

```bash
cd cloudflare
npm ci
npx wrangler login
npx wrangler secret put SECRET_KEY_BASE      # mix phx.gen.secret, or openssl rand -base64 64
npx wrangler secret put UI_BASIC_AUTH        # user:password
npm run deploy
```

The runner is then at `https://hcp-conformance.<your-subdomain>.workers.dev`.

## Settings

| Name | Kind | Meaning |
| --- | --- | --- |
| `SECRET_KEY_BASE` | secret, required | Signs and encrypts the session cookie. Without it the Worker answers 503 and says how to set it. |
| `UI_BASIC_AUTH` | secret, recommended | `user:password` in front of the runner and the API. The runner fetches any URL a visitor gives it, so a public instance should have it. |
| `REFERENCE_HOOK_SECRET` | secret, optional | The reference implementation's hook secret. |
| `ALLOW_PRIVATE_TARGETS`, `MAX_CONCURRENT_RUNS`, `REFERENCE_SERVER` | vars in `wrangler.jsonc` | As in the repository README. |
| `PHX_HOST` (and `PHX_URL_SCHEME`, `PHX_URL_PORT`) | var, optional | The public URL. Left unset, it is the address the first request arrives on, so workers.dev needs nothing. Set it for a custom domain. |

A running container keeps the environment it started with, so a changed secret applies after
the next deploy or the next wake from sleep.

## What the Worker does, and why

- **Redirects plain http to https** itself, so a redirect never wakes a sleeping container. The
  release's `force_ssl` stays on as the second line and adds HSTS.
- **Sets `x-forwarded-proto`** from the visitor's request, never trusting the client's, because
  the hop to the container is plain http.
- **Asks the container for uncompressed responses.** The Workers runtime adds `Accept-Encoding`
  to its own fetch, so without this a client that asked for no compression would get gzip. That
  includes the suite when it targets the runner's own `/reference`, and it checks raw responses.
  Cloudflare's edge still compresses for clients that ask.
- **Forwards the LiveView WebSocket** by using the container's `fetch`, not `containerFetch`.

`/health` and Cloudflare's readiness probes (`containerstarthealthcheck`, `localhost`) are exempt
from `force_ssl` in `config/prod.exs`, because a redirect there never succeeds.

## Develop

```bash
npm test          # the Worker's logic (src/environment.ts), with Vitest
npm run check     # TypeScript
npm run dev       # wrangler dev: builds ../Dockerfile and runs it locally (needs Docker)
```

Under `wrangler dev` the runner is at `http://localhost:8787`. Local addresses skip the https
redirect. Note that wrangler's dev proxy rewrites `Location` headers to its own scheme, so
redirects there are not what production sends.
