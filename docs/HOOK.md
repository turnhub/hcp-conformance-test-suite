# The HCP conformance hook

The hook is the same three calls for HCP v1 and v2. What follows describes them
for v1; [HCP v2](#hcp-v2) at the end says what differs.

HCP v1 draft 4, §5.4, says a first-party implementation still needs "a means
for the suite to obtain a credential and trigger grant creation", and that the
conformance suite's own specification defines a test hook for it. That
specification is not published yet, so this suite defines the hook below. It is
three HTTP calls. An implementation exposes them on test and staging deployments
only.

With the hook, the suite starts every run in a fresh, empty subject and creates
exactly the grants each check needs, so every check can run and none depends on
data already in the instance. Without it, the suite runs with credentials you
supply and skips the checks that need grants created on demand.

## Authentication

Every call carries the shared hook secret as a bearer token:

```
Authorization: Bearer <hook secret>
```

A missing or wrong secret is answered with 401. Choose a long random secret,
enable the hook only where conformance runs happen, and never on production data.

## Base URL

The hook lives at any URL you choose, given to the suite as `hook_url`. The paths
below are relative to it. The suite's reference implementation uses
`{HCP base URL}/conformance-hook`.

## POST {hook_url}/subjects

Creates a new, empty subject: an HCP instance (or a person within one) with no
entries, no grants and an empty audit log. Returns a credential for the person.

Request body (informational; implementations may ignore it):

```json
{ "purpose": "HCP conformance run" }
```

Response `201`:

```json
{
  "subjectId": "4f0c…",
  "subjectDid": "did:hcp:user:4f0c…",
  "personToken": "…"
}
```

| Member | Required | Meaning |
| --- | --- | --- |
| `subjectId` | yes | Identifies the subject in the calls below. Opaque to the suite. |
| `personToken` | yes | A bearer token that acts as the person (the subject) on the HCP REST transport: never redacted, allowed on the person-only endpoints (`/v1/audit`, `/v1/export`, `DELETE /v1/grants/{id}`, hard delete). It must live at least as long as a run, about 15 minutes. |
| `subjectDid` | no | The subject's identifier, used as `claim.subject.id` in the entries the suite writes. Defaults to a placeholder when absent. |

## POST {hook_url}/subjects/{subjectId}/grants

Issues a grant in the subject's instance as the subject's own affirmative act,
exactly as if the person had approved it, and returns the client's bearer token.

The grant must be indistinguishable from one obtained through the
implementation's real authorization channel. It appears in `GET /v1/grants`, is
enforced on every request, can be revoked with `DELETE /v1/grants/{id}`, and
produces a `grant.issued` audit event. The event records the expiry and
restrictions (§4.1.4, §4.1.5.1) and names the hook as the modality, for example
`modality=conformance-hook`.

Request body:

```json
{
  "clientId": "hcp-conformance-abcdefgh",
  "clientName": "HCP conformance client hcp-conformance-abcdefgh",
  "actorType": "agent",
  "scopes": ["hcp:health_context:read", "hcp:health_context:write"],
  "grantType": "temporary",
  "expiresInSeconds": 3600,
  "restrictions": [
    { "scope": "hcp:health_context:read", "narrowedTo": { "entryIds": ["urn:uuid:…"] } }
  ]
}
```

| Member | Required | Meaning |
| --- | --- | --- |
| `clientId` | yes | The client's identifier, unique per call. |
| `clientName` | yes | The human-readable client name for the grant object (§4.1.5). |
| `actorType` | yes | Always `"agent"` in this version of the suite. |
| `scopes` | yes | `hcp:{category}:{read\|write}` strings (§4.1.1). |
| `grantType` | yes | `"temporary"` or `"persistent"` (§4.1.4). |
| `expiresInSeconds` | for temporary | Lifetime from now. The suite asks for as little as 2 seconds to test expiry, and never more than 86 400. |
| `restrictions` | no | Narrows the grant below category grain (§4.1.5.1). If the implementation does not support narrowed grants, it answers 4xx and the suite skips the restriction check. |

Response `201`:

```json
{
  "grantId": "urn:uuid:…",
  "token": "…",
  "expiresAt": "2026-10-09T13:00:00Z"
}
```

| Member | Required | Meaning |
| --- | --- | --- |
| `grantId` | yes | The grant's id, as `GET /v1/grants` will show it. |
| `token` | yes | A bearer token for the client, on the HCP REST transport. |
| `expiresAt` | for temporary | The grant's absolute expiry. |

An invalid request (malformed scope, a restriction on a scope the grant does
not hold, a temporary grant longer than 24 hours) is answered with 422.

## DELETE {hook_url}/subjects/{subjectId}

Disposes of the subject and everything in it at the end of a run. Answer `204`
(or `200`). The suite ignores failures, so implementations that prefer to keep
test subjects for inspection may answer 405.

## What the suite does with it

1. Creates a subject and keeps its person token.
2. Issues a default agent grant: temporary, one hour, read and write on the
   primary category (the first supported category, or the one you pick).
3. Issues further grants as checks need them: read-only, two-second expiry,
   narrowed to one entry, or a second client to check that grants are never
   disclosed to another client.
4. Deletes the subject at the end.

Hook responses are recorded in the run's transcript with their tokens redacted.
They are excluded from the checks on response format, because the hook is not
part of the HCP surface.

## HCP v2

HCP v2 draft 3 keeps the hook, in §20.2: a First-Party implementation still
needs a means for the suite to obtain a credential and trigger grant creation,
and "the suite specification defines a test hook". This is that definition. The
section also notes that a grant created through the hook is not the Authorizing
Principal's act, so a deployment holding a real person's context cannot offer
it.

The three calls, their paths and their authentication are unchanged. Two things
differ.

### The person's credential is a Management Client

`personToken` authenticates a Management Client acting for the Authorizing
Principal, who is the Context Subject (§3.2.3). It performs the governance
operations of §5.4 (grants, audit log, export, hard delete, confirmation,
categories, purposes, standing rules, directives) as well as context
operations, receives entries whole and names them by `id`. `subjectDid` is the
Context Subject's identifier, in any URI form: the suite writes it as
`subject.id` in every entry, and a v2 provider rejects an entry that names
anyone else (§4.2), so return it.

### A grant is described by its access

The request to `POST {hook_url}/subjects/{subjectId}/grants` carries `access`
and `operator` in place of v1's `scopes`, `restrictions` and `actorType`:

```json
{
  "clientId": "hcp-conformance-abcdefgh",
  "clientName": "HCP conformance client hcp-conformance-abcdefgh",
  "operator": { "id": "https://conformance.hcp.example", "name": "HCP conformance suite" },
  "access": [
    {
      "actions": ["read", "write"],
      "categories": ["general_preferences"],
      "purposes": [
        { "code": "https://conformance.hcp.example/purposes/conformance-check", "description": "HCP conformance run" }
      ],
      "narrowedTo": { "entryIds": ["urn:uuid:…"] }
    }
  ],
  "grantType": "temporary",
  "expiresInSeconds": 3600
}
```

| Member | Required | Meaning |
| --- | --- | --- |
| `clientId`, `clientName` | yes | As for v1: the Context Client the grant is issued to. |
| `operator` | yes | The client's Client Operator (§3.2.8), recorded as `client.operator` on the grant. The suite names operators of its own to test standing rules, so record what is sent. |
| `access` | yes | The grant's authorization details (§6.1.5): `actions` (`read`, `write`, `provenance`), `categories`, and the `purposes` approved, each with a `code` and a `description`. Add the `type` yourself. |
| `access[].onwardSharing` | no | Elects onward sharing for the detail (§6.1.4, §6.1.5), as the person's separate act would: `{}` for any organization, or `{"domains": [...]}`. Refuse it for a detail that does not read, or has a category above Low sensitivity. |
| `access[].narrowedTo` | no | Narrows the detail (§6.1.5.1). The suite uses `entryIds`, holding entry `id`s. A key you do not support must be refused: the suite sends one to check that unknown narrowing fails closed. |
| `grantType`, `expiresInSeconds` | as for v1 | Temporary or persistent, and the lifetime of a temporary grant. |

The response is v1's: `grantId`, `token` and `expiresAt`. The token
authenticates the Context Client on every binding the implementation exposes:
as a bearer on the HTTP Binding and on the MCP endpoint alike. The client
registers no notification endpoint, so its disclosures are usable for an hour
at most (§7.6).

The grant must be indistinguishable from one obtained through the real channel:
listed by `GET /v2/grants` as a grant object, enforced on every request, and
recorded as `grant.issued` with its `access`, `grantType`, `expiresAt` and a
`modality` naming the hook. Answer 4xx, and issue nothing, when:

| Request | Why |
| --- | --- |
| A detail with no purpose, an unknown action or a category you do not hold | §6.1.5, §6.1.5.2 |
| A `narrowedTo` key you do not support | §6.1.5.1, rule 2 |
| `onwardSharing` on a detail with a category above Low sensitivity | §6.1.5 |
| A category a standing rule denies the `operator` | §6.3 |
| A temporary grant longer than 24 hours | §6.1.4 |

Without the hook, a v2 run takes `person_token`, `agent_token` and the subject's
identifier (`subject_did`), which v2 entries must name.
