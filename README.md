# HCP conformance suite

A standalone conformance test suite for the **Human Context Protocol (HCP) v1**,
draft 4 (`1.0-draft-4`). Point it at any HCP implementation reachable over HTTP,
and it checks the implementation against the specification and reports each
requirement as passed, failed, skipped or not applicable, with the HTTP exchanges
behind every finding.

It runs three ways from one codebase:

- **Hosted**: a stateless Phoenix app. Connect to a target, press run, and watch
  the results stream in. Credentials live only in your encrypted session cookie.
- **CLI**: `mix hcp.conformance` or the Docker image. Exits non-zero on failure,
  so it fits CI.
- **API**: `POST /api/runs` on a hosted instance answers with the report, for
  pipelines that should not install anything.

It also has a **portable memory chat**: ChatGPT and Claude using memories that
live in the target's HCP vault, only through grants the person issues, narrows
and revokes on the page (see [Portable memory](#portable-memory)).

It ships with a **reference HCP implementation** that passes every check. The
suite's own tests run against it twice: once as written, and once with a
deliberate defect per check, to prove that each check catches the defect it
exists for.

| | |
| --- | --- |
| Specification | HCP v1, 1.0-draft-4 (September 2026) |
| Checks | 94 (see [docs/CHECKS.md](docs/CHECKS.md)) |
| Transports | RESTful HTTP in full; MCP manifest only |
| Built with | Elixir 1.20, Phoenix 1.8 and LiveView, daisyUI; no database |
| Guardrails | Boundary, Credo (strict), Dialyzer and the test suite, locally (`mix precommit`) and in GitHub Actions |

## Contents

- [Quick start](#quick-start)
- [Portable memory](#portable-memory)
- [What a target needs](#what-a-target-needs)
- [What it checks](#what-it-checks)
- [Reading a report](#reading-a-report)
- [Hosting it](#hosting-it)
- [Running it against Turn's hcp_vault](#running-it-against-turns-hcp_vault)
- [Developing the suite](#developing-the-suite)
- [Known limits](#known-limits)

## Quick start

### Hosted

Open the hosted instance and connect: give the HCP base URL and either the
conformance hook (a full run) or existing tokens (a partial run). The run page
says which mode that gives and what it means for the run.

**What to check.** Each group is a toggle with its number of checks; **All** and
**None** set them all. The page counts what the selection covers (checks, MUST
and SHOULD) and says when it is not a conformance claim, which is anything short
of every group. Press **Run the suite**.

**Results.** While the run goes, a progress bar counts checks, the check running
now is named with its requests so far, and the stats count passed, failed,
warnings, skipped, errors and N/A. Results land in a collapsible section per
group, the same groups as the toggles, each headed with its counts by status. A
group opens when one of its results did not pass, and so does that result; groups
that passed stay folded. Opening or folding a section is yours to change while
results keep arriving.

Each result expands to the HTTP requests behind it: method and path, status,
time taken, and, expanded again, the request and response headers and bodies
(JSON pretty-printed). The discovery checks show the discovery request made
during setup, which is what they judge. Setup and teardown traffic (discovery,
the hook subject and grants) has rows of its own above the groups.

When the run ends, the summary shows the **verdict**, the MUST and SHOULD counts
and the target's capabilities, filters narrow the results to those not passed,
passed, or skipped, and the full report downloads as JSON.

Credentials are redacted everywhere: in the results, the report and the requests
shown with them. That covers the suite's bearer tokens, the hook secret, the tokens the hook hands
out (registered as secrets before their response is shown) and cookies in either
direction. Requests go straight from the run to your page. They are not written
to the server's logs, so other people's payloads never land in the operator's
log files. **Use the reference implementation**
shows a passing run without any setup. The run reaches the reference inside the
instance, on loopback at `http://127.0.0.1:$PORT/reference`, not through the
public URL, so a proxy or login in front of the instance (Cloudflare Access, for
one) cannot turn its requests away.

The app is stateless. The connection, credentials included, is kept in your
session cookie, which is encrypted as well as signed. A run lives in the page
that started it: closing the tab stops it, and nothing is stored on the server.

### Locally, in the browser

```bash
mix setup               # deps, plus the Tailwind and esbuild binaries
mix phx.server          # http://localhost:4000, reference implementation at /reference
```

Locally, targets on localhost and private networks are allowed.

### CLI with Mix

```bash
git clone https://github.com/turnhub/hcp-conformance-test-suite.git
cd hcp-conformance-test-suite
mix deps.get
export HCP_HOOK_SECRET=…           # credentials from the environment stay out of shell history
mix hcp.conformance \
  --target https://vault.example.com \
  --hook-url https://vault.example.com/conformance-hook \
  --json report.json
```

### CLI with Docker

```bash
docker build -t hcp-conformance .
docker run --rm -e HCP_HOOK_SECRET hcp-conformance bin/conformance \
  --target https://vault.example.com --hook-url https://vault.example.com/conformance-hook
```

### API

```bash
curl -s -X POST https://hcp-conformance.example.com/api/runs \
  -H 'content-type: application/json' \
  -d '{"target":"https://vault.example.com","hook_url":"https://vault.example.com/conformance-hook","hook_secret":"…"}'
# 200 with the full report, once the run finishes; 422 for an invalid request;
# 429 with Retry-After when the instance is running as many suites as it allows.
```

`GET /api/checks` returns the catalogue. The API keeps nothing: the response is
the report.

### CLI flags

| Flag | Meaning |
| --- | --- |
| `--target URL` | HCP base URL. The discovery document is read from `{target}/.well-known/hcp-configuration`. |
| `--discovery-url URL` | Discovery document elsewhere; the target is derived from it. |
| `--hook-url URL`, `--hook-secret S` | The conformance hook: a full run. Secret also from `HCP_HOOK_SECRET`. |
| `--person-token T` | Without a hook: a person credential. Also `HCP_PERSON_TOKEN`. |
| `--agent-token T` | Without a hook: a client with read and write on the category. Also `HCP_AGENT_TOKEN`. |
| `--subject-did D` | The subject's DID, written as `claim.subject.id`. |
| `--category C` | The category to work in. Defaults to the first supported one. |
| `--groups a,b` / `--only id,id` | Run a selection. The verdict then says it is not a conformance claim. |
| `--json FILE` | Write the full report, transcript included. |
| `--verbose` | Print the HTTP exchanges behind each failure. |
| `--strict` | Exit 1 when the run is incomplete, not only when it fails. |
| `--allow-private` | Allow loopback and private addresses (local and self-hosted use). |
| `--list` | Print the check catalogue. |

Exit status: `0` when no MUST check failed, `1` when one did, `2` for a usage error.

## Portable memory

The **Chat** page demonstrates what HCP is for: memory that belongs to the person,
reached by assistants only through grants the person issues. Every mechanic is
explicit on the page; nothing is granted implicitly.

1. Connect to a target as for a run, with the conformance hook (**Use the reference
   implementation** works). The page connects as the person, in a fresh subject,
   and issues **no grant**.
2. Give an API key for ChatGPT (OpenAI), Claude (Anthropic), or both, and
   optionally a model (`gpt-5.4-mini` and `claude-opus-5-5` by default). Each
   assistant is a separate HCP client with grants of its own.
3. **Grants.** Issue a grant to an assistant: which categories, read and/or write,
   temporary (with an expiry) or persistent, and optionally narrowed to particular
   memories (§4.1.5.1). The conformance hook stands in for the vault's consent
   screen. Every grant is listed with its scopes, type, expiry and status, and can
   be revoked.
4. **Memories.** Save memories as the person, or as an assistant through its grant
   (which needs write), with category, dimension, declaration type (user-declared,
   model-inferred, issuer-attested) and confidence. An inference that contradicts
   something the person declared on the same dimension is quarantined as
   conflicted (§2.6) and is not recalled. **Export** downloads the vault as JSON.
5. **Chat.** Each message is searched in the vault with the chosen assistant's own
   grant, and only what the vault returns is passed on. Under each reply, a list
   says exactly what happened. Its first row is the search: who chose the words
   (the assistant, you, or the message itself), each word, and the categories
   searched. Its second is the outcome: the assistant holds no grant, the vault
   refused it (with the status and problem type, for example 401 after a
   revocation or 403 for a category outside the grant), nothing matched and why,
   or the memories sent. By default the assistant picks the search words
   first, in a separate call: it is told how the vault searches and which
   categories its grant covers, never what is in the vault. That matters because
   the reference implementation's search is lexical (its discovery document says
   so): a memory comes back only if it shares a word with the query, so "what do
   you know about me?" searched as it stands finds nothing. If picking fails, the
   message itself is searched and the reply says so. **Search settings** can
   instead search the message itself or words you set, search categories beyond
   the grant (which the vault refuses), and set the number of memories, full or
   minimal detail, and the purpose recorded in the audit log. Untick the vault to
   send a message with nothing from it.

   Replies are rendered as Markdown, warily: they come from a vendor that saw the
   person's memories. Raw HTML shows as text, links to scripts are dropped, and
   images are never loaded (an image shows as its description), since a browser
   fetches an image without asking and its URL could carry recalled memories to
   another host.
6. **HCP calls** lists every request the page made to the vault, with the response,
   credentials redacted. The **Audit log** shows what the vault recorded, newest
   first: grants issued and revoked, reads with their purpose, writes, conflicts.

The page holds no state. API keys stay in the encrypted session cookie, the
conversation and grant tokens live in the page, and requests ask OpenAI
(`store: false`) and Anthropic not to keep anything. Claude requests opt into
Anthropic's server-side fallbacks, so a declined request is retried on a fallback
model rather than refused. The memories an assistant recalls do go to its vendor,
so use synthetic data or a vault whose owner agrees. The hook subject is deleted
when the page closes cleanly. `OPENAI_BASE_URL` and `ANTHROPIC_BASE_URL` point the
page at compatible endpoints instead.

Issuing grants needs the hook. With a person token instead, the page can still
list and revoke grants, show the audit log and export.

## What a target needs

The suite runs in one of three modes, chosen from what you supply.

| Mode | You supply | What runs |
| --- | --- | --- |
| **Hook** | `hook_url` and `hook_secret` | Every check. The suite starts in a fresh, empty subject and creates the grants each check needs. |
| **Static** | `person_token`, optionally `agent_token` | Everything that does not need grants created on demand. The suite works inside the existing subject, finds its own entries by unique words, and hard-deletes them at the end. |
| **Anonymous** | Nothing | The discovery document and unauthenticated transport checks. |

**The conformance hook** is three HTTP calls an implementation exposes on test
deployments. They create a subject, issue a grant as that subject's own act, and
delete the subject. HCP §5.4 says the conformance suite's specification defines
such a hook, but that specification is unpublished, so this suite defines it in
[docs/HOOK.md](docs/HOOK.md). The reference implementation's version is in
`lib/hcp_conformance/reference/server.ex`.

## What it checks

94 checks in eleven groups. Each names its section and its strength (MUST or
SHOULD). The full list with the requirement each check tests is in
[docs/CHECKS.md](docs/CHECKS.md).

| Group | Covers |
| --- | --- |
| `discovery` | The discovery document: members, vocabularies, durability window, profile and Tier 2 consistency (§3.3, App. C) |
| `transport` | `HCP-Version` negotiation, bearer authentication (§3.4.1, §3.4.4) |
| `entries` | Add, get, update, soft and hard delete; server-assigned fields; envelope validation; versioning; the audit event of each operation (§2.2, §3.3) |
| `idempotency` | Replays and key conflicts on POST, PUT and DELETE, without duplicate audit events (§3.4.3) |
| `search` | Response shape, purpose, default and ceiling, no padding, relevance order, redaction, no counts, category bound, minimal mode (§3.3.1, §3.1.1, §4.4) |
| `conflicts` | Detection in both write orders, normalization, quarantine from agents at every version, reject, accept, deleted authority (§2.6) |
| `grants` | Grant objects, per-client disclosure, temporary bounds, revocation, expiry, read-only scopes, narrowed grants (§4.1, §4.2) |
| `audit` | Event structure, agents refused, cursor pagination, cursor opacity, append-only (§4.3, §3.4.2) |
| `export` | Person only, default contents, `exclude=deleted`, `include=versions`, `include=audit`, audited (§3.3.5) |
| `mcp` | The MCP manifest, when MCP is declared (App. B) |
| `responses` | Run-wide, over every response: `hcp_version`, media types, RFC 9457 problems, registered types, `Retry-After`, no 5xx (§3.4) |

The `responses` group checks every response the target gave during the run, not
just a sample.

## Reading a report

| Status | Meaning |
| --- | --- |
| `pass` | The target met the requirement. |
| `fail` | The target broke a MUST. |
| `warn` | The target broke a SHOULD. |
| `skip` | The check could not run with what this run had, such as no hook or no second category. |
| `error` | The suite could not complete the check: the target was unreachable, or a bug in the suite. |
| `n/a` | The requirement does not apply by the target's own declaration, such as MCP checks for a REST-only target. |

The **verdict** is `pass` when every applicable MUST check passed, `fail` when
any failed, and `incomplete` when nothing failed but some MUST checks were skipped
or errored. A run narrowed with `--groups` or `--only` is marked as selected
checks only, never as a conformance claim.

The JSON report holds the full transcript: every request and response, with
tokens and secrets replaced by `[redacted]`.

## Hosting it

The image is a Phoenix release. It serves the runner, the API and the reference
implementation on one port, and needs no database or shared storage.

```bash
docker build -t hcp-conformance .
docker run -p 4000:4000 \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e PHX_HOST=conformance.example.com \
  hcp-conformance
```

**Kubernetes**: publishing a GitHub release runs `.github/workflows/release.yml`,
which pushes the image to
`europe-west3-docker.pkg.dev/turn-tooling/turnhub/hcp-conformance:<release tag>`.
Give the container port 4000, point the liveness and readiness probes at
`GET /health` (exempt from the HTTPS redirect), take `SECRET_KEY_BASE` from a
Secret, and set `PHX_HOST` to the ingress host. Set `BIND_ADDRESS=0.0.0.0` if the
pods have no IPv6.

**Google Cloud Run**:

```bash
gcloud run deploy hcp-conformance --source . --port 4000 \
  --set-env-vars PHX_HOST=…run.app,BIND_ADDRESS=0.0.0.0 \
  --set-secrets SECRET_KEY_BASE=hcp-conformance-secret-key-base:latest --allow-unauthenticated
```

Because it is stateless it scales to several instances. The concurrency cap below
then applies per instance.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SECRET_KEY_BASE` | required to serve | Signs and encrypts the session cookie. Generate with `mix phx.gen.secret`. |
| `PHX_HOST` | `example.com` | The public host name. |
| `PHX_URL_SCHEME`, `PHX_URL_PORT` | `https`, `443` | The public URL's scheme and port. Set `http` and the port for a plain-http run without a TLS proxy. |
| `PORT` | `4000` | Listening port. |
| `BIND_ADDRESS` | `::` (all, IPv6 included) | Set `0.0.0.0` on hosts without IPv6. |
| `ALLOW_PRIVATE_TARGETS` | `false` in the image, `true` locally | Allow targets on loopback and private networks. Leave off on a public instance. |
| `MAX_CONCURRENT_RUNS` | `4` | Runs at once per instance. More are refused (429 on the API). |
| `UI_BASIC_AUTH` | unset | `user:password` to put the runner and the API behind basic auth. `/health` and `/reference` stay open. |
| `REFERENCE_SERVER` | `true` | Serve the reference implementation at `/reference`. The demo button reaches it on `127.0.0.1:$PORT`, so `BIND_ADDRESS` must include loopback (the default and `0.0.0.0` both do). |
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` | The Responses API the chat page calls for ChatGPT. |
| `ANTHROPIC_BASE_URL` | `https://api.anthropic.com/v1` | The Messages API the chat page calls for Claude. |
| `REFERENCE_HOOK_SECRET` | `reference-hook-secret` | The reference hook's secret. The connect page's demo button uses it: the reference holds only synthetic, in-memory data. |

**Security notes for a public instance.**

- The runner fetches whatever URL a visitor submits. It refuses hosts that
  resolve to private, loopback or link-local addresses unless
  `ALLOW_PRIVATE_TARGETS` is set. The one exception is the instance's own
  reference implementation on loopback (`http://127.0.0.1:$PORT/reference` and
  paths under it), which holds only synthetic data. The resolved address is not
  pinned for the connection, so also deploy it without access to internal
  networks.
- Hook secrets and tokens are never stored on the server. They live in the
  visitor's encrypted session cookie, and transcripts and reports redact them.
- Visitors hand the instance credentials for their own systems. Run a public
  instance only where people can trust its operator, or put it behind
  `UI_BASIC_AUTH`.

## Running it against Turn's hcp_vault

Turn's vault app (`priv/apps/lua/dev/hcp_vault` in [turnhub/engage](https://github.com/turnhub/engage)) serves HCP under its app URL:

```
--target https://whatsapp.turn.io/apps/<app install uuid>
```

It has no conformance hook yet, so run it in static mode. Get a person token with
the vault's `generate_person_token` journey function (one hour, 24 at most), and
pass it with `--person-token`. The vault mints no client tokens yet, so checks
needing an agent are skipped and the verdict is `incomplete`.

Adding the hook (docs/HOOK.md) to the vault would enable every check. Its
kernel already issues grants as the person's act, so the hook is a thin wrapper
over `Hcp.issue_grant` and `Tokens.generate`.

## Developing the suite

```bash
mix setup
mix test           # about 130 tests, 10 seconds; no network beyond localhost
mix precommit      # compile with warnings as errors (Boundary included), unused deps,
                   # format, credo --strict, tests, dialyzer
mix hcp.checks > docs/CHECKS.md    # after adding or changing a check; a test enforces it
```

**Guardrails.** Boundary fails the build when a module reaches across a boundary
it does not declare: the suite (`HcpConformance`), the reference implementation
(`HcpConformance.Reference`) and the web app (`HcpConformanceWeb`) only call each
other through their exports. Credo runs strict, Dialyzer checks the typespecs,
and new behaviour starts as a failing test. GitHub Actions
(`.github/workflows/ci.yml`) runs each guardrail as its own check on every push to
`main` and every pull request: formatting, Credo, Dialyzer, the tests, and a
smoke test that builds the release image and runs the suite from it against its
own reference implementation.

**Supply chain.** Everything pulled from outside is pinned: GitHub Actions to a
commit SHA, and every container image (the CI jobs' and the Dockerfile's) to a
digest, which the "Pinned images" check enforces. Dependabot
(`.github/dependabot.yml`) proposes Hex, Actions and image updates weekly, a
week after each release so a compromised one is usually pulled before we take
it. OSV-Scanner (`.github/workflows/dependency_scan.yml`) scans `mix.lock`
against the Erlang Ecosystem Foundation's and GitHub's advisories on every
dependency change and every six hours on `main`, failing on HIGH or CRITICAL;
an accepted risk goes in `osv-scanner.toml` with its reason.

The test endpoint listens on port 4002, so the LiveView and API tests run real
suites against the reference implementation the app serves.

The tests run every check against the reference server in hook, static and
anonymous mode, and require a clean pass. `test/fault_detection_test.exs` then
switches on one defect at a time in the reference server, such as padding search
results or leaking a conflicted entry's old version. It requires the matching check
to fail and the others to keep passing. Two checks were blind to their defect
until these tests caught it.

**UI.** Pages use the components Phoenix generates (`core_components.ex`) and
daisyUI component classes, nothing hand-styled. AGENTS.md records this for
agents working in the repo.

**Adding a check.** Add a `Check.new/6` to the right module in
`lib/hcp_conformance/checks/`. Then add a fault to the reference server and a
case to the fault tests that proves the check catches it. Finally, regenerate
docs/CHECKS.md.

Layout:

| Path | What |
| --- | --- |
| `lib/hcp_conformance/checks/` | The checks, one module per group |
| `lib/hcp_conformance/runner.ex`, `context.ex`, `report.ex` | Running a suite: setup, sequencing, verdict |
| `lib/hcp_conformance/http.ex`, `transcript.ex`, `target_guard.ex` | Talking to targets, recording, redaction, private-network guard |
| `lib/hcp_conformance/envelope.ex` | The §2.2 envelope rules, in either form |
| `lib/hcp_conformance/reference/` | The reference HCP implementation and its conformance hook |
| `lib/hcp_conformance/runs.ex`, `settings.ex` | Starting runs from the web, the concurrency cap, deployment settings |
| `lib/hcp_conformance/vault.ex`, `assistants.ex`, `open_ai.ex`, `anthropic.ex` | The chat page's vault client (grants, memories, recall, audit, export) and the assistants it talks to |
| `lib/hcp_conformance_web/` | The Phoenix app: connect page, run and chat LiveViews, API, reference mount |
| `lib/hcp_conformance_web/exchanges.ex`, `markdown.ex` | The HTTP exchange component both pages show; Markdown for docs pages and replies |
| `docs/HOOK.md`, `docs/CHECKS.md` | The hook protocol (also served at `/hook`) and the check catalogue (`/checks` lists the same checks) |

## Known limits

- **MCP**: the manifest is checked; tool calls over MCP are not exercised yet.
- **OAuth 2.0**: declared endpoints are checked for presence; the flows are not
  run. First-party implementations are fully covered through the hook.
- **Tier 2 / VC-Extended**: declarations are checked; signed credentials are not
  submitted or verified.
- **Durations**: cursor validity for 300 s and rate limiting under load are not
  provoked. `Retry-After` is checked on any 429 the run happens to receive.
- **Durability**: `preference.read` events are awaited for the declared window
  plus three seconds; other events for three seconds. A suite cannot observe
  durability itself, only visibility.
- **The JSON Schema**: HCP has not published its Tier 1 schema (Appendix D). The
  envelope rules are written out from §2.2 and will be swapped for the schema
  once it exists.
