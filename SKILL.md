---
name: immybot
description: This skill should be used when working with ImmyBot — an RMM/MSP automation platform. Covers calling the ImmyBot REST API (OAuth2 client-credentials auth, global/local script and software catalogs, maintenance sessions), creating Immy tenants and enrolling RMM devices without onboarding sessions, inventory-then-tenant-scoped deployments (LatestVersion / UpdateIfFound), the end-to-end software install/deploy playbook (identify via primary user, catalog check, upload/analyze, ad-hoc + ongoing deployments), software detection triage (SoftwareTable name/mode mismatches, Regex exact-match, read-only detection previews), post-session verification + Thread customer follow-up (@mentions from session results), and writing ImmyBot PowerShell content (detection scripts, dynamic-version scripts, install/uninstall scripts, config/maintenance tasks with test-get-set, Invoke-ImmyCommand and other built-in Immy cmdlets). Trigger on "ImmyBot", "immy.bot", "create Immy tenant", "enroll from RMM", "inventory then deployments", "push a script to Immy", "install software", "deploy software", "check sessions", "timed install", "detection script", "detection failing", "software table name", "dynamic versions script", "config task", "maintenance task", "Invoke-ImmyCommand", or RMM software-deployment automation.
version: 1.6.0
---

# ImmyBot

ImmyBot is an RMM automation platform (MSP-focused). Tenants run at `https://<subdomain>.immy.bot`.
Everything below was verified against live ImmyBot Swagger specs and APIs — not guessed from
general docs. See `references/` for the deep dives; this file is the map.

## Tenant onboarding + present-software deployments (new customer)

When asked to stand up Immy for a customer that already has devices in the MSP RMM — create
tenant → enroll without sessions → inventory → tenant-scoped deployments — follow
**`references/tenant-onboarding-and-deployments.md`**. Do not invent a parallel process.

Checklist (ask before **every** mutation; read-only discovery is fine):

1. **Identity invariant** — confirm `{Immy tenant name+id, provider-link name+id, RMM customer/site name+id, expected device count}` (+ hostname sample) before any customer-scoped write.
2. **Create tenant** — `POST /api/v1/tenants` (`name` unique, `ownerTenantId` = MSP, optional Azure `principalId`), then `PATCH /api/v1/tenants/activate/{id}`.
3. **Enroll without sessions** — **prefer Datto RMM** (your Datto RMM provider-link id): link the Datto site/client to the Immy tenant, then let agents sync. Confirm `linkedToTenantId` and that devices land under the right tenant with no onboarding sessions. Manual ImmyBot Agent PowerShell install (`.../powershell-install-script-with-onboarding` + `automaticallyOnboard=false`) is fallback only. Never paste raw install scripts into the skill/Slack/board. Pilot one device when using the script path.
4. **Inventory** — prefer `GET /api/v1/tenants/software-from-inventory/{tenantId}`. Refresh jobs need
   their own approval + completeness threshold before shortlisting.
5. **Deployments** — shortlist significant apps already in Immy (match by software id +
   Global/Local). Desired states are **not** interchangeable: `LatestVersion` (5) ≈ keep updated /
   install if missing; `UpdateIfFound` (7) ≈ update only where found. Tenant scope is typically
   `targetType = AllForTenant` + `tenantId`. Full deployment approval = manifest; read back after
   each create. Do **not** enqueue fleet sessions unless explicitly asked — but document whether
   saving the assignment will ride an existing schedule.
6. **Tracking** — Thread = operational source of truth; board card = status/time; Slack only if
   post-worthy and sanitized.

Label durable notes as `Observed` / `Swagger` / `read-back` / `Unresolved` (see the reference doc).

## Software install / deploy playbook (ALL software)

When asked to install software for named users or machines, follow this path — do not invent a
one-off process. Applies to **every** title (CAD apps, browsers, vendor tools, etc.).

1. **Identify devices via primary user first.** Search the tenant's computers and match on Immy
   **primary user** (name/email). **Keep primary users up to date** — agents and operators should
   treat that hygiene as part of the workflow, because it is how “whose machine is this?” gets
   solved without guessing hostnames.
2. **Multiple computers for one user.** Compare **last time each machine talked to Immy** (last
   agent contact / inventory). Prefer the most recently seen box for ad-hoc. If a second machine
   has not checked in for **more than a few weeks**, ignore it for the ad-hoc session (ongoing
   deployments can still be broader when intentional).
3. **Confirm the machine is genuinely theirs before targeting.** Check Immy inventory for **last
   signed-in user** (or run a short read-only check on the endpoint via terminal / `scripts/run`).
   If it looks right, **ask the operator to confirm** the target before creating the deploy.
4. **Prefer person-targeted ad-hoc when it fits** — ad-hoc can target the **user**, not only the
   hostname. Still verify the active machine looks like that user’s daily driver first.
5. **Prefer hostname targeting when person records are stale risk.** If the tenant is **not** a
   solid Microsoft 365 directory shop (e.g. Google Workspace / manual user sync), Immy people can
   go stale when someone switches computers and nobody updates primary user. In those cases, target
   the **hostname** (computer) after confirmation — safer than a stale person link.
6. **Check Global and Local catalogs** for existing software. Prefer an existing **Global** title when
   it is already battle-tested by the ImmyBot community. **Custom / MSP-authored writes stay Local**
   unless the operator explicitly wants Global community publish.
7. **If software is missing — always ask before fetching an installer:** *“Should I go look for the
   installer, or do you have a link I should use?”* Only hunt after they say so; if they give a
   link/path, upload from that. Then Local upload → analyze / fast-create so Immy can generate
   detection/install scripts.
8. **If generated scripts look generic or wrong — fix them** (silent args, detection, complex
   vendor installers often need this). Smoke-test one machine when practical.
9. **Timed ad-hoc via `POST /api/v1/run-immy-service-new`** (not weekly `/schedules`, and not
   `scripts/run`). This enqueues maintenance sessions; returns **202** with an empty body when
   `sessionGroupId` is set. Populate exactly one of `computers` / `persons` / `tenants`.
   - **`updateTime`**: `"HH:mm"` 24-hour string. **Null / omit = start immediately.** With a time set,
     the session is queued for that clock time in `timeZoneInfoId` (e.g. `America/Los_Angeles`). If
     that time already passed today, it rolls to the **next day**. Requires SchedulesFeature.
   - **`rebootPreference`**: `Force` = `-1`, `Normal` = `0`, `Suppress` = `1`, `Prompt` = `2`.
   - **`offlineBehavior`**: `Skip` = `1`, `ApplyOnConnect` = `2`. Always confirm with the operator.
   - **`desiredSoftwareState`**: usually `LatestVersion` = `5` for “install/update to newest.”
   - **Do not call `run-now`** if the intent is “configure for tonight / later.”
10. **`suppressRebootsDuringBusinessHours` — easy to get wrong, high impact.** The UI/default often
    leaves this `true`. That flag is **independent of `rebootPreference`**: even with **Force**,
    Immy can still defer reboots that fall inside the computer’s configured business hours. For
    after-hours Force installs (reboot before/after required), set
    **`suppressRebootsDuringBusinessHours: false`**. Leaving it `true` is a silent foot-gun — the
    session looks correctly Force-flagged but reboots may not happen when you expect. Always check
    this field before enqueueing. Put it in the skill checklist every time.
11. **Ongoing deployment** after the immediate need — target machine / user / tenant / group / tag
    so updates and new matching machines stay covered on later maintenance.
12. **Ask before blasting the fleet** — enqueue one target first, confirm the queued session in the
    UI looks right (time, Force, offline behavior, business-hours suppress), then clone the rest.
13. **Always follow up after sessions complete** — do not leave timed/overnight installs as
    “queued and forgotten.” See **Post-session follow-up (Thread)** below. Record session IDs when
    you enqueue; check results; **@mention each affected user** on the ticket with their outcome;
    log time; move the ticket to QAQC (or keep open on failures). Prefer scheduling that follow-up
    when you enqueue (next morning / after the last window).

Keep primary users and person↔computer links current; the playbook depends on them.

## Post-session follow-up (Thread) — mandatory after deploy work

Customer-facing software installs (especially **timed overnight ad-hoc**) are not done when the
session is queued. Close the loop the next morning (or once sessions finish):

### When you enqueue (same day)

1. **Capture session IDs** in an **internal** Thread note + board activity (person → hostname →
   session id → scheduled local time). Timed `run-immy-service-new` returns **202 empty** when a
   `sessionGroupId` is used — look up the created sessions in Immy (or note IDs from the UI) and
   write them down immediately.
2. **Schedule the follow-up** so it is not forgotten:
   - **Preferred:** Thread `schedule_ticket` for Dillon the **next business morning** (or ~1h after
     the last install window) with a description like: *Check Immy sessions \<ids\>; @mention users
     with Success/Failed; QAQC or rerun failures.*
   - **Same-session / still running:** Cursor loop / reminder to re-check until terminal status.
   - Do **not** schedule a customer-visible “it worked” note blindly — the follow-up must read
     live session/action results first.

### When you check results

1. **Prefer known session IDs** — `GET /api/v1/maintenance-sessions/{id}` then actions via
   `/api/v1/maintenance-actions/dx` with `filter=[["maintenanceSessionId","=",id]]`.
   - `sessionStatus` / `executionStageStatus`: `0=Passed`, `1=Running`, `2=Failed`.
   - On actions: `result` `1=Success`, `2=Failed` — read `resultReasonMessage` on failures
     (timeouts, “no version found”, etc.).
2. **If IDs were lost** — query `/maintenance-actions/dx` in **narrow UTC hour windows**
     (`requireTotalCount=false`), filter client-side by `tenantName` / software display name, or
     by `computerId`. Do **not** pull multi-day windows in one call (timeouts). Filter out
     `actionType=0` (NoAction) when hunting installs.
3. **Map computer → person** via `GET /api/v1/computers/{id}` → `primaryPerson`
     (`displayName`, `emailAddress`). List endpoints often omit person fields — use per-ID GET.
4. **Thread customer reply with @mentions (per person, not one vague blast):**
   - `search_contacts` to resolve names already on the ticket when needed.
   - Customer-visible `add_ticket_note` (`is_internal: false`) — address **each** user by name and
     state **their** machine + outcome. Prefer **one note per person** when several people are on
     the ticket (clearer than one mega-reply).
   - **Mention gotcha (MCP):** blocked on no secondary-resource / mention tool — `@Name` in
     `add_ticket_note` is plain text (see thread-ticket-ops **@mentions**). Still use `@First Last`
     for readability; for a real Inbox ping, re-@ in Thread UI (or a proven secondary-resource path).
     `send_to_email` only when Dillon asks.
   - **Success:** ask them to open/launch the app, confirm it looks good, and reply on the ticket
     if anything is wrong.
   - **Failed / partial (multi-machine user):** say we’re still fixing / ask to reschedule a rerun
     (same window when that was the prior plan); do **not** ask them to “verify the install” as if
     it succeeded. Include a short honest reason when it helps (timeout, detection miss) without
     dumping raw logs.
5. **Ticket hygiene:** `log_time_entry` for the check + follow-up; set status **QAQC** when
   successes are ready for customer validation (keep ticket open / Work in Progress if critical
   targets still failed — note failures internally and plan reruns).
6. **Board:** activity note with the same Success/Failed table; keep the card `in_progress` +
   weekly deliverable while hours should show on the grid.

### Why schedule from Immy output (not a fixed canned reply)

Immy session results are the source of truth. A scheduled Thread calendar entry (or agent reminder)
should trigger **“read sessions → draft @mentions from results → post”**, never a pre-written
“all good” message. Partial failures are common (timeouts, detection lag, offline apply-on-connect
still pending) — treat them explicitly.

## Auth (do this first)

ImmyBot API auth is **Azure AD OAuth2 client-credentials** — an app registration, not a user login.

```powershell
$tenantId     = $env:IMMYBOT_AAD_TENANT_ID
$clientId     = $env:IMMYBOT_CLIENT_ID
$clientSecret = $env:IMMYBOT_CLIENT_SECRET
$immyBase     = $env:IMMYBOT_BASE_URL   # e.g. https://yourcompany.immy.bot

$tok = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "$immyBase/.default"
}).access_token
$headers = @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" }
```

Full copy-paste script: `scripts/Connect-ImmyBot.template.ps1` (reads from env vars — fill in your
own tenant's values, or point at a project that already has a filled-in copy).

**Discover the live API yourself** — every tenant's Swagger spec is authoritative and current
(enum fields often carry human-readable `x-enum-descriptions`):
```powershell
$sw = Invoke-RestMethod -Uri "$immyBase/swagger/v1/swagger.json" -Headers $headers
$sw.paths.PSObject.Properties.Name | Sort-Object          # every route
$sw.components.schemas.<SomeEnum>                          # enum meanings, in plain English
```

## Core concepts

- **Global vs Local catalog** (`DatabaseType`) — this is NOT "shared across your tenants vs one
  tenant." **Global = ImmyBot's shared/community catalog that syncs across *every ImmyBot instance*;
  writing there effectively publishes your script to the public ImmyBot codebase. Local = *your own
  instance's* catalog (your MSP), private to your company.** Most entities (scripts, software,
  maintenance tasks, media) exist in both `.../global` and `.../local` route trees with parallel shapes.
  **Default to Local for anything you write** — normal MSP work (a registry fix, a config task, a
  detection script, a client remediation) is Local, and that's correct; Local is not "wrong" or
  "siloed." **Don't create in / migrate to Global unless the explicit intent is to publicly contribute
  the script to the shared ImmyBot community catalog.** "Private vs reusable across *your own* tenants"
  is a *separate* axis — tenant **visibility within** your Local catalog (`visibleToAllTenants`), not
  Local vs Global. The create response doesn't echo `visibleToAllTenants` back, so verify via
  `GET /api/v1/scripts/local/{id}/authorization`. When in doubt, Local.
- **Scripts** are the atomic unit. A `Script` has: `name`, `action` (the PowerShell/CMD body — **field
  is `action`, not `scriptContent`**), `scriptLanguage`, `scriptExecutionContext`, `scriptCategory`,
  `timeout`, `outputType`.
- **Software** is a higher-level entity that *wires scripts together*: a detection method/script, an
  install/uninstall/upgrade/repair script, an optional test script, and optionally a dynamic-versions
  script + download-installer script instead of static versions.
- **Maintenance Tasks** (shown as "Config Tasks" in the UI when `isConfigurationTask` is true) wire up
  to three scripts — test / get / set — often all three pointing at *the same script*, which branches
  internally on an implicit `$method` variable (`"test"`, `"get"`, `"set"`). See the built-in
  hibernation-style example in `references/scripting-guide.md`. **For registry-only config tasks,
  don't hand-roll that `switch ($method)` — use the built-in `$method`-aware `RegistryShould-Be` /
  `HKCUShould-Be` helpers (Metascript context)**, which collapse test/get/set into a few declarative
  lines and auto-fan-out HKCU across all user profiles + the Default profile. See
  `references/scripting-guide.md` ("PREFER the built-in `*Should-Be` helpers" section).
- **Invoke-ImmyCommand** is the bridge: Metascript-context code (runs on the ImmyBot backend, has
  access to `Get-ImmyComputer`, tenant data, etc.) hands a scriptblock to `Invoke-ImmyCommand` to
  actually execute *on the target endpoint*. Use `$using:` to pass variables across that boundary,
  exactly like `Invoke-Command`. Full verified parameter list in `references/scripting-guide.md`.
- **"Onboarding" is ImmyBot's own term for a *device* lifecycle state** — a new/reimaged computer
  being brought under management for the first time (`NeedsOnboarding` status, the onboarding
  wizard, `set-to-needs-onboarding`/`skip-onboarding` endpoints, `onboardingOnly` on tasks). If your
  own project also uses the word "onboarding" for something else (e.g. onboarding a *person* into
  apps/accounts), these are unrelated concepts that happen to share a name — don't reach for
  ImmyBot's onboarding-flow endpoints just because your task is also called "onboarding." A
  `MaintenanceTask`/`Software` deployment with `onboardingOnly: false` runs through completely
  normal maintenance-session mechanics, with no connection to the device-onboarding feature at all.

Read `references/scripting-guide.md` before writing any ImmyBot script — it has the full
`ScriptCategory`/`ScriptExecutionContext` semantics, the verified `Invoke-ImmyCommand` signature, all
43 built-in `*-Immy*` cmdlets, and worked examples (detection, dynamic-versions, config task).

**Dynamic Versions (category 9)** — prefer existing Global software with a working DV script; when
authoring Local, **call a shared `Function` helper** (`Get-DynamicVersionFromInstallerURL`,
`Get-DynamicVersionsFromURL`, `Get-DynamicVersionsFromGitHubUrl`, etc.) instead of hand-rolling
HTTP/regex. Copy `scriptExecutionContext = 4` from a live DV script (not Metascript `2`). Full
decision tree, helper params, return envelope, and named-capture conventions live in
`references/scripting-guide.md` → **Dynamic Versions playbook**.

Read `references/api-reference.md` before calling the REST API — it has pagination/filter query params,
the script-push pattern, ad-hoc script execution, maintenance-session rerun/status endpoints,
local-software PATCH, and `run-immy-service-new` phase flags (`detectionOnly` / `inventoryOnly` / etc.).

## Software detection triage (false “missing” installs)

When impact reports / sessions say install/repair because software “wasn’t installed yet,” but operators
suspect it **is** installed — check detection before reinstalling:

1. **Read the software record** — `GET /api/v1/software/local/{id}` (or global). Note
   `detectionMethod`, `softwareTableName`, `softwareTableNameSearchMode`, `upgradeCode`.
2. **Read endpoint inventory** — `GET /api/v1/computers/{computerId}/detected-computer-software`.
   Compare installed `softwareName` rows to `softwareTableName`. If inventory shows the real app name
   but detection is pointed at a different string, Immy will keep trying to install.
3. **`SoftwareTable` + `Contains` is a substring trap.** Example (verified OUN / UNIFI): table name
   `UNIFI` with Contains also matches **Chaos Unified Login** (`Unified` contains `unifi`). Prefer
   **`softwareTableNameSearchMode = Regex`** with an anchored pattern, e.g. `(?i)^UNIFI$`, when the
   display name must be exact (case-insensitive). Wrong table name is worse — e.g. detecting
   `Content Catalog` while inventory says `UNIFI` → fleet-wide false missing.
4. **Patch local software** — `PATCH /api/v1/software/local/{id}` with
   `UpdateLocalSoftwareRequestBody` (replace-style: send current fields + the detection fix;
   include `*ScriptType` `Global`/`Local` for script refs). Read back `softwareTableName` + mode.
5. **Preview before fleet** — do **not** enqueue installs to validate detection. Run a **read-only**
   Metascript via `POST /api/v1/scripts/run` (`scriptExecutionContext = 2`) that
   `Invoke-ImmyCommand`s uninstall-key enumeration and applies the **same** regex/logic. Confirm
   `WouldDetect=true` and that near-miss names are excluded. Optionally use
   `run-immy-service-new` with `detectionOnly: true` (no install) — see api-reference.
6. **Then install on a pilot** — `POST /api/v1/run-immy-service-new` with
   `maintenanceType: LocalSoftware` (or Global), `maintenanceIdentifier: "<softwareId>"`,
   `desiredSoftwareState: LatestVersion`, `computers: [{ computerId }]`, null `updateTime` for now.
   Returns **202** empty when `sessionGroupId` is set — resolve session via
   `/maintenance-sessions/dx` filtered by `computerId` (newest), then poll
   `/maintenance-sessions/{id}` + `/maintenance-actions/dx`.

Full field notes: `references/scripting-guide.md` (Software entity). Wire examples:
`references/api-reference.md` (PATCH software + run-immy flags + session lookup).

## Gotchas (bite people every time)

- **`suppressRebootsDuringBusinessHours` vs Force reboot.** Setting `rebootPreference` to Force does
  **not** override this flag. If suppress-during-business-hours is `true`, after-hours Force jobs can
  still defer reboots. For intentional Force before/after installs, set it `false` and verify on the
  queued session. (Caught live on a timed `run-immy-service-new` ad-hoc — UI defaults often leave it on.)
- Timed ad-hoc installs use `POST /api/v1/run-immy-service-new` with `updateTime` (`HH:mm`), not
  weekly `/schedules`, and not immediate `scripts/run`. Null `updateTime` = run now.
- **After any timed/overnight deploy: follow up.** Record session IDs at enqueue time; next morning
  (or via Thread `schedule_ticket` / agent reminder) read session+action results, @mention each
  user with Success vs Failed, log time, QAQC. Never post a canned “all good” before reading Immy.
- Script body field is `action`, not `scriptContent`.
- List-style GET endpoints (e.g. `maintenance-sessions?computerId=X`) return the HTML SPA instead of
  JSON — only per-ID GETs (`/maintenance-sessions/{id}`) work through the API.
- **`/maintenance-actions/dx` OR filters across multiple `maintenanceSessionId`s → 500.** One session
  per call. Wide multi-day pulls time out — use hour/day windows with `requireTotalCount=false`.
- Computer **list** responses often omit `primaryPerson`; use `GET /api/v1/computers/{id}` for
  displayName/email when drafting Thread @mentions.
- Raw API JSON serializes enum fields (`scriptCategory`, `scriptExecutionContext`, etc.) as **integers**,
  and those integers do **not** reliably match the declaration order shown in the Swagger enum
  description. Don't compute an enum's integer from its position in the doc — fetch a real existing
  script/task of the category you want and copy its integer, or use the `Filters=field==N` query to
  probe (see `references/scripting-guide.md` for confirmed mappings).
- PS5.1 `Expand-Archive` requires a `.zip` extension — copy `.whl`/other archive files to a temp `.zip`
  first.
- `Set-Content -Encoding UTF8` on PS5.1 adds a BOM. If a downstream file parser (Python `.env`, a
  `._pth` file, etc.) chokes on the first line, write with
  `[System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::ASCII)` instead.
- `useScriptParamBlock=true` on a maintenance task only works when its Set script's execution
  context is `Metascript` — fails on `System`-context scripts (needed for filesystem/registry work
  on the endpoint) with "param blocks can only be used with metascripts." For System-context
  scripts, declare the task's `parameters[]` explicitly instead; they arrive as pre-set
  script-scope variables (no `param()` block needed) — see `references/api-reference.md`.
- **When creating a stand-alone maintenance task, the "Runs Against" selector is the single
  easiest thing to get wrong, and ImmyBot is unforgiving about it.** The four radio options map to
  the target/type fields: **Computers** (`maintenanceTaskCategory = Computer`,
  `isConfigurationTask = false`, UI says "This is a normal maintenance task") is a normal task that
  runs on the endpoint — the correct default for almost everything (registry/filesystem work,
  enforcing settings, running a script on machines). **Cloud** = `Tenant`, **People** = `Person`
  (task runs against the tenant/person, not a device). **Software (Configuration Task)** sets
  `isConfigurationTask = true` and attaches the task to a *Software* item so it can inject
  runtime/parameter configuration into that software's install — it's more complex and only correct
  when you are *specifically* parameterizing an installer. **The trap:** a Configuration Task is
  *not* selectable on the Edit Deployment page and can't be deployed on its own — it only fires when
  its associated Software is detected/installed on the machine (per ImmyBot's own docs). So a task
  you meant to run everywhere, marked as a config task, will silently never run as a normal
  deployment. Rule of thumb: **unless the task exists to inject runtime parameters for an installer,
  pick Computers.** Common miss: creating a normal task as *Software (Configuration Task)* when it
  should have been *Runs Against: Computers*, so it never deploys on its own. When in doubt, choose
  Computers.
- `GET /api/v1/computers` uses plain `name`/`tenantId` query params, not the `Filters=` Sieve
  syntax that `/scripts` and `/software` use — check each route's own params in Swagger.
  **Gotcha:** `?tenantId=` is unreliable in practice — always filter the list client-side on
  `.tenantId` before trusting scope. The unfiltered list is often **incomplete / not a full
  fleet dump** — for “online machines in tenant X,” prefer Thread MCP `search_immybot_computers`
  (`tenant_id` + `online`) or per-name lookups, then `GET /api/v1/computers/{id}`.
- **Per-ID computer GETs use `computerName`, not `name`.** List/search payloads often expose
  `name`; `GET /api/v1/computers/{id}` returns `computerName` (plus `isOnline`, `tenantId`,
  `primaryPerson`, …). Don’t assume one property name everywhere.
- **SoftwareTable `Contains` ≠ exact name.** Substring matches cause false positives
  (`UNIFI` ⊆ `Chaos Unified Login`). For exact display-name detection use Regex
  `(?i)^DisplayName$` (or UpgradeCode/ProductCode when MSI identity is stable).
- **False missing installs are often detection, not package.** If inventory already has the app
  under the real name but sessions keep Install/Repair-missing, fix `softwareTableName` /
  search mode (or custom detection) before blasting reinstalls.
- New-customer tenant / enroll / inventory / tenant deployments: see
  **Tenant onboarding + present-software deployments** above and
  `references/tenant-onboarding-and-deployments.md`.
- `POST /api/v1/scripts/run` lets you test a script/task against a computer with parameter and
  variable overrides (e.g. simulate `$method`) without deploying anything — see
  `references/api-reference.md`. For anything unproven, prefer a strictly read-only preview variant
  rather than trusting `-WhatIf`.
- Detection/version scripts commonly run `scriptExecutionContext = Metascript` and reach onto the
  endpoint via `Invoke-ImmyCommand { ... } -Verbose`, returning a version string (or `$null` if not
  installed) — not a boolean. See the Chrome / store-app detection examples in
  `references/scripting-guide.md`.
- **`POST /api/v1/scripts/run` has a hard ~120s gateway timeout** (observed as `504 Gateway Timeout` /
  `stream timeout`) — it's a synchronous streaming call that blocks until the script finishes. For
  anything that legitimately runs longer, make the script itself return fast (a "submit and don't
  wait" mode) and poll the real downstream result separately. Full pattern in
  `references/api-reference.md`.
- **Run API calls from `pwsh` (PowerShell 7+), not legacy `powershell.exe` (5.1).** Windows PowerShell
  5.1 can hang indefinitely on `ConvertTo-Json -Depth 20` for otherwise trivial objects — the request
  never leaves the machine. The same payload runs immediately in `pwsh`. If a GET-mutate-POST script
  "hangs" with no error, check which binary is running before debugging the network.
