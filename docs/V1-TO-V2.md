# HCP v1 → v2: what moved and what it means for implementers

**In one line.** v2 (currently 2.0-draft-3) reorganizes the protocol more than it
extends it. The wire format, the conformance model and the security model all
change, so a v1 implementation needs a port, not an upgrade. The draft is
unstable: later drafts will change the wire again, and every identifier in it is
a placeholder.

This is a summary for people deciding what a move to v2 costs. How the suite
checks v2, and the gaps found in the draft while writing those checks, are in
[V2.md](V2.md).

## What moved

| Area | v1 (1.0-draft-4) | v2 (2.0-draft-3) |
| --- | --- | --- |
| Conformance | One level: Core, Interop or VC-Extended | A list of claims: Core, each binding, each profile. Each is claimed whole. |
| Who calls | "User" and "agents" | A Management Client for the person, Context Clients for apps. Governance (grants, audit, export, hard delete, confirmation) is the person's alone and HTTP-only. |
| Entries | Two tiers, two envelope forms, one category each | One entry shape with content profiles; several categories per entry. The flat form is gone. |
| What an app receives | The stored entry, lightly redacted | A disclosure: no stable id, a reference unique to that grant, and a time after which the copy must not be used. |
| Consent | Category and read/write scopes; purpose was free text per query | Scopes plus purposes the person approves, enforced on every read. Standing rules and directives apply across all grants. |
| Provenance | A `userVerified` flag the caller sets | The provider records who asserted, submitted and authorized each version. "The person said this", from an app, is unverified until the person confirms. |
| Conflicts | Same category and dimension means conflict; the person's entry always wins | Decided by standing, not type. Detection is the provider's own declared method, in an optional profile. |
| Updates | `PUT` with new text | A revision that names the version it replaces, and fails if stale. |
| Bindings | MCP and REST as equals; either alone sufficed | HTTP is required to accept outside clients. MCP carries app operations only, loses hard delete, gains two tools. |
| Revocation notice | HMAC-signed webhook | Signed Security Event Tokens with published keys. |
| Credentials | Verify either of two mechanisms | `eddsa-rdfc-2022` is mandatory to verify; credential status is checked. |
| Audit | Free-text detail | Structured events naming every participant. |
| New | — | Delegation (guardians, caregivers), onward sharing, import, a disclosure summary, end-to-end encrypted storage. |

## What carries over unchanged

- **Grants:** temporary by default, 24-hour maximum, a separate act to elect
  persistence.
- **Revocation:** takes effect on the very next request.
- **Minimization:** default 5, ceiling 20, no padding, no pagination of results.
- **Audit:** the durability rules and opaque cursors.
- **Errors and retries:** RFC 9457 errors with the same six codes (three added),
  and idempotency keys.
- **Token lifetimes**, and the test-hook concept for first-party vaults.

## What it means for implementers

- **Budget for a rewrite of the API surface.** Paths, entry shape, discovery
  document and audit events all change. v1 entries are converted on import,
  never upgraded in place.
- **Decide your claims first.** A first-party vault may expose either binding.
  Accepting anyone else's clients requires the HTTP Binding and OAuth.
- **Clients take on obligations.** They must honour use-until times, stop using
  copies on revocation, and report onward sharing. Entry ids can no longer be
  stored or compared across apps.
- **The provider does more bookkeeping.** Per-grant references, purpose
  enforcement, provider-set provenance and, if it accepts model inferences, the
  Memory Manager Profile.
- **Some v1 behaviour is reversed.** Accepting an inference no longer rewrites
  it as the person's statement, and an app-written "person-declared" entry can
  now be quarantined.
- **Rebuild two integrations if you have them.** Revocation webhooks, and
  credential verification for anyone who chose the canonicalization-free path.
- **Don't hard-code identifiers.** Schema, conformance, problem-type and MCP
  extension URIs all use `hcp.example` and will change.
- **Schemas now exist.** v1 never published its JSON Schema; v2 publishes
  schemas for entries, grants, operations and events.
- **Expect ambiguity.** Draft 3 leaves gaps; 27 are listed in
  [V2.md](V2.md#review-notes-on-draft-3).

## What v1 promised for v2

| Deferred in v1 | In Draft 3? |
| --- | --- |
| Guardian and delegated consent | Yes |
| Credential status and revocation | Yes |
| One mandatory securing mechanism | Yes |
| Entry versioning for migration | Yes |
| End-to-end encrypted storage | Yes, flagged as under review |
| Automated conflict resolution | No; proposals only |
| Federation between vaults | No |
| On-device execution | No |

*Based on a full read of both drafts: v1 from the Draft 4 reference
specification (September 2026), v2 from the
[public specification repository](https://github.com/loyalagents/hcp-spec) at
commit `b790561`.*
