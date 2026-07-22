# Tenant onboarding + present-software deployments

Evidence labels used below:

| Label | Meaning |
|---|---|
| `Verified by live Swagger` | Confirmed against `https://yourcompany.immy.bot/swagger/v1/swagger.json` |
| `Verified by read-back/API test` | Called live and inspected the response |
| `Observed` | Done on a pilot customer during a live session |
| `Unresolved — do not operationalize` | Hypothesis only |

Do **not** copy raw agent install scripts, tokens, or `taskParameterValues` into this file, Slack, or board notes.

---

## Goal

For a customer that already has devices in the MSP RMM:

1. Create an Immy tenant
2. Enroll those devices into Immy **without** kicking maintenance / onboarding sessions
3. Read inventory (prefer existing; refresh only when approved)
4. Propose significant apps that already exist in Immy (Global/Local)
5. Create **tenant-scoped** deployments (`LatestVersion` keep-updated-and-install, or `UpdateIfFound` update-only-where-present)
6. Do **not** enqueue fleet maintenance sessions unless the operator explicitly asks

---

## Hard gates (Codex-folded)

### Identity invariant (before any customer-scoped mutation)

Display and confirm:

`{ Immy tenant name + id, provider-link name + id, RMM customer/site name + immutable id, expected device count }` + a small hostname sample.

Abort on mismatch, ambiguity, duplicate tenant name, or unexpected count.

### Approval posture

Ask before **every** mutating step: create/activate tenant, generate/apply enroll script, inventory refresh that executes on endpoints, each deployment batch, any session. Read-only discovery is fine without approval.

Each deployment approval must be a **manifest**:

`{ tenant name/id, software name/id/database type, desired-state fields + plain-language behavior, target type/id, matching device count, future-device inheritance, schedule/session consequence, parameters with secrets redacted }`

Approval applies only to that manifest. Re-read the saved assignment after create; stop the batch on mismatch.

### No sessions on enroll

**Preferred path: Datto RMM integration** — `Observed` on a pilot customer:

1. Ensure **Datto RMM** provider-link is present and enabled (look up Datto RMM provider-link id on your instance).
2. Create/activate the Immy tenant.
3. Link the Datto site/client to that Immy tenant (`POST .../provider-links/{id}/clients/link-to-tenant`, or Immy UI / Datto integration UI). Confirm the identity tuple: Datto `externalClientId` + Immy `tenantId`.
4. Let Datto→Immy agent sync bring devices in. Do **not** kick onboarding sessions as part of linking. Verify computers land under the correct `tenantId` with no unintended maintenance sessions.
5. Manual PowerShell agent install scripts are a **fallback only** (broken/disabled RMM link, non-Datto customer, or operator explicitly asks).

**Pilot link (`Observed`):** confirm Datto `externalClientId` ↔ Immy `linkedToTenantId` for the customer before proceeding.

**Fallback — ImmyBot Agent install script** (`Verified by live Swagger` + `Verified by read-back/API test`):

- ImmyBot Agent provider (`provider-links` id **2**) does **not** support `POST .../powershell-install-script` (NotSupported). Use:

  `POST /api/v1/provider-links/2/agents/powershell-install-script-with-onboarding`

  with `onboardingOptions.automaticallyOnboard = false` (and follow-up email off).

- Never persist the raw script body into the skill. Save only to an operator-local path outside git if needed.
- Pilot: enroll **one** confirmed device first → verify `tenantId` + no maintenance session / not `NeedsOnboarding` → separate approval for the rest.
- Session checks: before enroll, immediately after apply, after first agent check-in, and after the next relevant schedule boundary.

### Desired software states (do not conflate)

`Verified by live Swagger` — `DesiredSoftwareState`:

| Enum | Int | Plain language (working) |
|---|---|---|
| `LatestVersion` | 5 | Keep on latest; will install if missing |
| `UpdateIfFound` | 7 | Update only where already detected / applicable — **not** the same as LatestVersion |
| `AnyVersion` | 2 | Present at any version |
| `NotPresent` | 1 | Uninstall / ensure absent |
| `NoAction` | 6 | Detect only / no enforce |

`Verified by read-back/API test`: existing MSP assignments heavily use `desiredSoftwareState` 5 and 7. Tenant-scoped software deployments commonly use **`targetType = AllForTenant` (21)** with `tenantId` set, `onboardingOnly = false`, `targetEnforcement = Required` (1).

---

## Phase checklist

### 0 — Context (read-only)

1. Pull Thread / board ask for customer legal name + RMM pointers.
2. Confirm no duplicate Immy tenant name/slug.
3. List provider-links; note which are `disabled`.
4. Skim only the routes needed for the next approved step (tenants, provider-links agents/clients, software-from-inventory, target-assignments).

### 1 — Create tenant

`Verified by live Swagger` + `Observed`:

`POST /api/v1/tenants` body (`CreateTenantRequestBody`):

```json
{
  "name": "<customer>",
  "slug": "CODE",
  "ownerTenantId": 1,
  "isMsp": false,
  "principalId": null,
  "partnerPrincipalId": null,
  "parentTenantId": null,
  "limitToDomains": null
}
```

Naming convention observed across the instance: `"Display Name (CODE)"` with matching slug.

- `ownerTenantId` is the MSP tenant id on your instance (`isMsp: true`) — look it up via `GET /api/v1/tenants` before create — `Verified by read-back/API test`.
- Duplicate names fail — `Verified by live Swagger` description.
- After create: `PATCH /api/v1/tenants/activate/{id}` so the tenant can participate in maintenance later — `Verified by live Swagger` + `Observed` (POST returns 405; PATCH works).
- Creating a tenant does **not** auto-link Azure (`azureTenantLink: null` unless `principalId` provided).

**Pilot result (`Observed`):** confirm created tenant id/name/slug/`ownerTenantId`, then activate.

### 2 — Link Datto RMM client (preferred) / fallback install script

**Preferred — Datto RMM (`Observed`):**

1. `GET /api/v1/provider-links/69/clients` — find the Datto site (`externalClientId`, name).
2. Link to the Immy tenant if not already linked:
   - `POST /api/v1/provider-links/69/clients/link-to-tenant` with `{ "clientIds": ["<dattoExternalClientId>"], "tenantId": <immyTenantId> }`
   - Or use Immy/Datto UI (what was used for the pilot).
3. Optional: `POST .../clients/link-to-new-tenant` creates a tenant from a Datto client in one step (`externalClientId`, optional `tenantName`) — useful when the Immy tenant does not exist yet.
4. Confirm read-back: client row shows `linkedToTenantId` = Immy tenant id.
5. Wait for / trigger agent sync as the operator prefers; verify computers under that tenant **without** onboarding sessions.

**Datto dynamic install script — required site variables** (full step:
`C:\Users\DillonDaniel\.claude\projects\New Client Onboarding - All Automation Tools\Datto-Immy-site-variables-immyID-immyKey.md`):

For the MSP Datto RMM **ongoing Immy install policy** (dynamic script), extract from that
tenant’s Immy agent `msiexec` command the MSI properties `ID=` and `KEY=` and enter them as
Datto **site variables** `immyID` and `immyKey`. The policy will not land agents for that site
until those are set. Treat `KEY` as a secret. Confirm a pilot device checks into the right tenant.

**Fallback — manual agent script:** after create/activate, ImmyBot Agent client appears at
`GET /api/v1/provider-links/{immyBotAgentProviderLinkId}/clients` (`externalClientId == linkedToTenantId == "<tenantId>"`). Generate non-auto-onboard script per Hard gates. Confirm other RMM provider-links are enabled before relying on them.

**Computer list gotcha (`Verified by read-back/API test`):** `GET /api/v1/computers?tenantId=X` may return an unfiltered fleet. Always filter client-side: `Where-Object { $_.tenantId -eq $tenantId }`.

### 3 — Inventory

Prefer:

`GET /api/v1/tenants/software-from-inventory/{tenantId}`

`Verified by live Swagger` + smoke-tested: returns rows with `displayName`, optional `globalSoftwareId` / `globalSoftwareName`, `computerId`, `computerName`, `dateDetectedUtc`.

Rules:

1. Prefer reading existing inventory before any refresh job.
2. If a refresh is required, classify mechanism (read request vs endpoint script vs RMM job vs maintenance session), show scope/side effects, get separate approval.
3. Completeness threshold before shortlisting: expected vs checked-in count, inventory age, offline/failed list, explicit exceptions.
4. Significant-app heuristics: business-critical, security-sensitive, frequently updated, broadly installed. Exclude drivers/runtimes/OEM/user-specific tools unless explicitly approved.
5. Match Immy catalog by **software id + database type**, not display name alone.

### 4 — Create tenant-scoped deployments

Prefer Immy UI “present software → create deployments” for the first verified path; API after the saved shape is known.

API create (`Verified by live Swagger`):

`POST /api/v1/target-assignments` with `CreateLocalTargetAssignmentPayload`.

Working template for tenant-wide software (`Verified by read-back/API test` of existing assignments):

```json
{
  "maintenanceIdentifier": "<softwareIdAsString>",
  "maintenanceType": "GlobalSoftware",
  "targetType": "AllForTenant",
  "targetCategory": "Computer",
  "tenantId": 588,
  "desiredSoftwareState": "UpdateIfFound",
  "targetEnforcement": "Required",
  "onboardingOnly": false,
  "excluded": false,
  "propagateToChildTenants": false
}
```

Use `"LatestVersion"` instead of `"UpdateIfFound"` when the operator wants install-if-missing + keep updated.

Before create: document whether saving the assignment attaches to an existing schedule / applies on next maintenance / affects future check-ins. Creating an assignment is **not** the same as `run-immy-service-new`, but it can still cause future sessions when schedules exist — treat as mutation with schedule/session consequence in the manifest.

After create: `GET /api/v1/target-assignments/{id}` (or UI) and compare every approved field; query for new sessions.

Optional helpers (`Verified by live Swagger` only — not yet deep-tested here):  
`POST /api/v1/target-assignments/tenant-target-preview`, `target-preview`.

### 5 — Tracking contract

- **Thread** = operational source of truth (tenant id, enroll reconciliation, exceptions, deployment manifests).
- **Automation board** = status/time + concise outcome on the parent card.
- **Slack work-log** = sanitized reusable-playbook summary only after Dillon confirms post-worthy.

---

## Sticky facts (per MSP instance — keep private; do not commit real ids)

Look these up on your tenant before first use (`GET /api/v1/tenants`, `/api/v1/provider-links`):

| Fact | How to find |
|---|---|
| Immy base | `IMMYBOT_BASE_URL` / connect script |
| MSP `ownerTenantId` | tenant with `isMsp: true` |
| Datto RMM provider-link id (preferred enroll) | provider-links list (name match) |
| ImmyBot Agent provider-link id (fallback install scripts) | provider-links list |
| Other RMM provider-links | confirm enabled/disabled before relying on them |
| Fallback non-onboarding install | `powershell-install-script-with-onboarding` + `automaticallyOnboard:false` |
| Tenant deploy target | typically `AllForTenant` + `tenantId` |
| Keep updated / install missing | `LatestVersion` (5) |
| Update only if found | `UpdateIfFound` (7) |

---

## What not to do

- Do not invent RMM provider script paths until verified.
- Do not store install script bodies, registration tokens, or cleartext deployment parameters in skill/chat/Slack/board.
- Do not treat a single UI observation as a universal Immy guarantee — label evidence.
- Do not enqueue maintenance sessions as part of enroll or as an automatic follow-on to deployment creation.
- Do not use display-name-only software matching for deployments.

