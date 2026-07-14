# ImmyBot API Reference

Verified live against a real tenant's `/swagger/v1/swagger.json` (466 documented paths). Base URL below
is written as `$immyBase` — substitute your tenant's `https://<subdomain>.immy.bot`.

## Auth

See `SKILL.md` for the full client-credentials flow. Summary: Azure AD app registration,
`grant_type=client_credentials`, `scope=$immyBase/.default`, token goes in `Authorization: Bearer`.

## Discovering the API yourself

Don't guess endpoints — pull the live spec, it's better than any static doc because it's guaranteed
current for *this* tenant's deployed version:

```powershell
$sw = Invoke-RestMethod -Uri "$immyBase/swagger/v1/swagger.json" -Headers $headers
$sw.paths.PSObject.Properties.Name | Sort-Object                     # list every route
$sw.paths.'/api/v1/scripts/global'.get.parameters                     # params for one route
$sw.components.schemas.ScriptCategory                                 # enum + x-enum-descriptions (plain English!)
```

Many `components.schemas.*` enums carry an `x-enum-descriptions` array with a one-line explanation per
value — read those before guessing what a field means.

There's also `/api/v1/scripts/functions` (GET, no params) — returns **all 707** PowerShell
cmdlets/functions available inside a script's runspace, `{ name, commandType }`. Filter to `*Immy*` to
get just the ImmyBot-specific ones (43 of them — full list in `references/scripting-guide.md`).

`GET /api/v1/metascript-catalog/search` and `/describe` are documented in Swagger (would return ranked
cmdlet/API search results and per-cmdlet parameter shapes) but returned 404 on the tenant tested —
likely a gated/newer feature not enabled on every plan. Don't rely on it; use the ad-hoc-metascript
introspection trick below instead, which works everywhere.

## Introspecting cmdlets live (better than any doc)

You have API access to actually *run* PowerShell against the backend. Use it to get ground-truth
`Get-Help -Full` output for any Immy cmdlet instead of guessing parameters:

```powershell
$body = @{
    scriptName = "introspect"
    scriptBody = "Get-Help Invoke-ImmyCommand -Full | Out-String -Width 200"
    computerId = <any real computer ID in the tenant>   # Metascript context requires one
} | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/scripts/run-adhoc-metascript" -Headers $headers -Body $body
```

`POST /api/v1/scripts/run-adhoc-metascript` runs an inline script body with no catalog entry needed —
either Metascript context (pass `computerId`) or CloudScript context (pass `tenantId`, backend-only, no
agent). Also takes `scriptExecutionTimeoutSeconds`, `agentConnectionWaitTimeoutSeconds`,
`invalidateFunctionScriptCache`. Requires `scripts:run` permission. Cancel a running one with
`POST /api/v1/scripts/debug/cancel/{cancellationId}`.

## Listing / searching global scripts

```
GET /api/v1/scripts/global?Filters=...&Sorts=...&Page=1&PageSize=50
GET /api/v1/scripts/search?globalOnly=true&localOnly=false&Filters=...&Page=1&PageSize=50
```

Response is a plain JSON array (not wrapped in a `{items: [...], total: N}` envelope) — `PageSize=50`
gives you 50 objects back directly. `Filters` takes Sieve/GridifyQL-style expressions, e.g.
`Filters=scriptCategory==0` to get only detection scripts. Confirmed working.

Get one script's full body (includes `action`): `GET /api/v1/scripts/global/{scriptId}`.
Get just names (cheap, for pickers): `GET /api/v1/scripts/global/names`.
Who references a script: `GET /api/v1/scripts/global/{scriptId}/references`.

## Pushing/updating a script

```powershell
$existing = Invoke-RestMethod -Uri "$immyBase/api/v1/scripts/local/<scriptId>" -Headers $headers
$existing.action = Get-Content "path\to\script.ps1" -Raw   # field is "action", NOT "scriptContent"
Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/scripts/local/<scriptId>" -Headers $headers -Body ($existing | ConvertTo-Json -Depth 20)
```

Same GET-mutate-POST pattern works for `/api/v1/scripts/global/{id}` if you have global-catalog write
access. There's also `POST /api/v1/scripts/duplicate` and a local→global migration pair:
`/api/v1/scripts/local/{id}/migrate-local-to-global` (+ `-what-if` dry-run variant).

**If this hangs with no error, check your PowerShell binary before anything else.** Confirmed live:
the exact GET-mutate-POST sequence above hung for 60s+ inside `ConvertTo-Json -Depth 20` — before
the POST even fired — when run via legacy `powershell.exe` (5.1), on a plain ~6KB object with no
nested structure to justify it. Switching to `pwsh` (PowerShell 7+) fixed it instantly, no other
changes. Don't waste time adding `-TimeoutSec`/try-catch/progress-bar workarounds first — confirm
which binary is actually running the script.

## Software (global catalog)

```
GET  /api/v1/software/global?Filters=...&Page=1&PageSize=50
GET  /api/v1/software/global/{softwareIdentifier}
GET  /api/v1/software/global/{softwareIdentifier}/versions
GET  /api/v1/software/global/{softwareIdentifier}/versions/{semanticVersion}
POST /api/v1/software/global/analyze         # analyze an installer to bootstrap a software definition
POST /api/v1/software/global/fast-create
POST /api/v1/software/global/upload
```

Full field list (detection method, install/uninstall/test/upgrade/repair script IDs, dynamic-versions
config, licensing) is in `references/scripting-guide.md` — it's the wire shape returned by these GETs.

## Maintenance tasks (= "Config Tasks" in the UI)

```
GET /api/v1/maintenance-tasks/global?Page=1&PageSize=50
GET /api/v1/maintenance-tasks/global/{id}
GET /api/v1/maintenance-tasks/global/{id}/param-block-from-parameters
```

Returns `testScriptId`/`getScriptId`/`setScriptId` (+ `testEnabled`/`getEnabled`/`setEnabled`),
`maintenanceTaskCategory` (Computer/Tenant/Person — which target type the task runs against),
`isConfigurationTask`, `onboardingOnly`, `executeSerially`, `parameters[]`, supersession chain fields.

## Running an ad-hoc script on a specific machine (not via catalog)

```powershell
$payload = [ordered]@{
    Script = [ordered]@{
        name   = "my-script-name"   # required
        action = $scriptContent     # PS code string
        scriptLanguage         = 2  # 2 = PowerShell
        scriptExecutionContext = 0  # confirm the right int for your case — see scripting-guide.md gotcha
        timeout = 60
    }
    body       = @{}
    computerId = <computerId>
} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/scripts/run" -Headers $headers -Body $payload
```

## Maintenance sessions

```powershell
# Rerun — key is "sessionIds" (array), NOT "maintenanceSessionId". Returns 204 No Content.
Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/maintenance-sessions/rerun" -Headers $headers -Body (@{ sessionIds = @(<sessionId>) } | ConvertTo-Json)

# Status
$s = Invoke-RestMethod -Uri "$immyBase/api/v1/maintenance-sessions/<sessionId>" -Headers $headers
# sessionStatus / executionStageStatus: 0=Passed, 1=Running, 2=Failed
```

List-style maintenance-session GETs (e.g. `?computerId=X`) return the HTML SPA, not JSON — only
per-ID GETs work through the API.

### DevExtreme `/dx` grids — how to query them at scale (verified live 2026-07-14)

The `*/dx` endpoints are DevExtreme DataSource endpoints. They take JSON query params
(URL-encode each): `filter`, `sort`, `select`, `group`, `groupSummary`, `totalSummary`,
`skip`, `take`, `requireTotalCount`, `requireGroupCount`. Hard-won rules from probing
`/api/v1/maintenance-actions/dx` on a tenant with ~74k actions/day:

- **`requireTotalCount=true` is the expensive/timeout part, NOT the date filter.** It
  forces a full `COUNT(*)` over the filtered set. Live: an hour window counted in 0.4s,
  a day (74,625 rows) took 38s, a week timed out (>70s). The row fetch itself is fast.
  **Never send `requireTotalCount=true` on a wide window** — page with
  `requireTotalCount=false` and stop on a short page.
- **Wide + sorted raw fetches also choke.** A week-wide `sort` + `take=1000` (no count)
  still timed out — sorting ~500k rows to return the first page is too much. Keep raw
  windows narrow (hour/day), or aggregate server-side (below).
- **Filter/group on the INTEGER enum fields, not the string `*Name` variants.**
  `group=`/`filter=` on `actionTypeName`, `resultName`, or `maintenanceTypeName` return
  **HTTP 500**. The underlying ints (`actionType`, `result`, `maintenanceType`) group and
  filter fine. The `*Name` strings ARE still returned in row data when listed in
  `select` — they just can't be grouped/filtered.
- **`select=["colA","colB",...]` works** and cuts payload/serialization a lot on wide rows.
- **No practical `take` cap:** `take=5000` returned 3,475 rows in one 0.5s call.
- **Server-side grouping is fast and the big win** for reporting. `group=` (single or
  nested) + `requireGroupCount=true` + `take=0` returns aggregated buckets, not raw rows:
  per-tenant counts for a day in ~1.4s, per-app counts in ~0.3s, nested full grain
  (`[tenantName, maintenanceIdentifier, actionType, result, computerId]`) in ~0.3s.
  Caveat: DevExtreme `groupSummary`/`totalSummary` support count/sum/min/max/avg but
  **NOT count-distinct** — get distinct computers by grouping on `computerId` (or nesting
  it) and reading `groupCount`/subgroup counts, not via a summary.

`maintenanceActions` enum ints (declaration order, confirmed against live volumes):
- `actionType`: 0=NoAction, 1=Install, 2=Update, 3=Uninstall, 4=Download, 5=Reinstall,
  6=Downgrade, 7=Undetermined, 8=TaskEnforce, 9=TaskMonitor, 10=TaskAudit
- `result`: 0=Pending, 1=Success, 2=Failed, 3=Cancelled, 4=Indeterminable, 5=Resolved

### Reporting on maintenance actions by week

**Preferred: action-first, day-windowed, with NoAction filtered server-side.** On a real
tenant ~95% of action rows are `actionType=0` (NoAction — pass-only checks). Excluding
them server-side collapses a day from ~74.6k to ~3.5k rows and a week from ~500k to ~29k,
so a whole day fits in ONE call. This is ~7 calls for a full week, vs one call per session
(14k+) for the session-first pattern below.

```powershell
# one call per day; loop the 7 days of the week. createdDateUTC is UTC.
$dayFilter = [uri]::EscapeDataString(
  '[["createdDateUTC",">=","07/07/2026 00:00:00"],"and",["createdDateUTC","<","07/08/2026 00:00:00"],"and",["actionType","<>",0]]'
)
$sort = [uri]::EscapeDataString('[{"selector":"createdDateUTC","desc":true}]')
$sel  = [uri]::EscapeDataString('["id","parentId","tenantId","tenantName","computerId","actionTypeName","resultName","maintenanceTypeName","maintenanceIdentifier","maintenanceDisplayName","maintenanceSessionId","reason","createdDateUTC"]')
$actions = Invoke-RestMethod -Uri "$immyBase/api/v1/maintenance-actions/dx?skip=0&take=5000&requireTotalCount=false&sort=$sort&filter=$dayFilter&select=$sel" -Headers $headers
# if a day ever returns exactly `take` rows, page with skip until a short page.
```

Or, for a headline report without pulling rows at all, group server-side (see the `/dx`
rules above) — e.g. `group=[{"selector":"maintenanceIdentifier","isExpanded":false},{"selector":"actionType","isExpanded":false},{"selector":"result","isExpanded":false}]&requireGroupCount=true&take=0` with the same day+`actionType<>0` filter.

**Fallback: session-first** (only if you specifically need per-session grouping the UI uses):
1. List sessions with `/api/v1/maintenance-sessions/dx?sessionType=2`, DevExtreme
   `filter=` on `createdDate` (`MM/DD/YYYY HH:mm:ss` strings, not Sieve `Filters=`), sorted
   `createdDate desc`.
2. For each session ID, `/api/v1/maintenance-actions/dx` with
   `filter=[["maintenanceSessionId","=",1308723]]` (optional fallback
   `/maintenance-actions/dx-for-computer/{computerId}` with the same filter). Note: an OR
   filter across multiple `maintenanceSessionId`s returns 500 `NotSupportedException`, so
   this is genuinely one call per session — avoid it for large weeks.

Also note: although Swagger lists `maintenanceActions` on `GetMaintenanceSessionResponse`,
live `GET /api/v1/maintenance-sessions/{sessionId}` responses did **not** include that field.

When aggregating actions, watch for parent/child rows. To avoid double-counting, build a set
of action IDs that appear as another action's `parentId`; credit child actions and standalone
actions, not parent rollup rows.

## Creating new scripts and maintenance tasks

`POST /api/v1/scripts/local` (`CreateLocalScriptRequestBody`) creates a brand-new script (as
opposed to the GET-mutate-POST pattern above, which only *updates* an existing one). Required:
`action`, `name`. On **create**, `scriptCategory`/`scriptExecutionContext`/`scriptLanguage` are
sent as their **string enum names** ("MaintenanceTaskSetter", "System", "PowerShell") — this
sidesteps the int-mapping gotcha entirely, use string names on create/update payloads always.
Also takes `ownerTenantId` (int, required — look up an existing script's value with
`GET .../authorization` if unsure which tenant ID to use) and `visibleToAllTenants` (bool). The
create response (`GetLocalScriptResponse`) does **not** echo back `visibleToAllTenants` — verify
what actually saved via `GET /api/v1/scripts/local/{id}/authorization` instead, which does.

`POST /api/v1/maintenance-tasks/local` (`CreateLocalMaintenanceTaskPayload`) creates a new
maintenance/config task. Required: `name`. Takes `tenantId` (not `ownerTenantId` — different field
name than the script payload), `visibleToAllTenants`, `setEnabled`/`setScriptId`/`setScriptType`
(+ same for test/get), `maintenanceTaskCategory`, `isConfigurationTask`, `useScriptParamBlock`.

**`useScriptParamBlock` only works when the set script's `scriptExecutionContext` is
`Metascript`.** Setting it `true` against a `System`-context script (needed for anything that
touches the filesystem/registry directly on the endpoint) fails creation with: `"The selected
script is not a metascript, and param blocks can only be used with metascripts."` For
System-context scripts, declare the task's parameters explicitly instead (see below) — they
arrive as pre-set script-scope variables, not a PowerShell `param()` block, exactly like
ImmyBot's own built-in config tasks (e.g. Hibernation's `$EnableHibernation` — no param block in
sight). Don't fight this; write the script to just reference `$ParamName` freely.

The `parameters` field is `readOnly` on the **create** payload (you can't set it in the same call
that creates the task) but *is* writable on **update** —
`POST /api/v1/maintenance-tasks/local/{id}` (`UpdateLocalMaintenanceTaskPayload`). Pattern: create
the task first, then GET it, replace `.parameters` with an array of
`{ id: 0, name, dataType, required, defaultValue, notes, hidden, order }` objects (`id: 0` for new
params), and POST the whole object back — same GET-mutate-POST shape as scripts. `dataType` enum
(`Number, Text, Boolean, Select, Password, File, Uri, KeyValuePair`) — confirmed empirically that
for *this* enum the backing ints do match declaration order (Number=0, Text=1, Boolean=2), unlike
`ScriptCategory`. Still prefer sending/reading the string name over relying on that.

## Deprecating, disabling, or deleting a maintenance task

There is **no per-task "enabled/disabled" flag** on a `MaintenanceTask` — only the per-method
`testEnabled`/`getEnabled`/`setEnabled` bools. So to **disable** an obsolete task without deleting
it (reversible, and keeps its history/notes intact), GET the task, set all three of
`testEnabled`/`getEnabled`/`setEnabled` to `false` (an ad-hoc run then becomes a no-op), prefix the
`name` with something like `[DEPRECATED - use '<replacement>']`, drop an explanation in `notes`, and
POST it back to `POST /api/v1/maintenance-tasks/local/{id}`. To **hard-delete** instead, `DELETE
/api/v1/maintenance-tasks/local/{id}`.

Before disabling/deleting a task, confirm nothing still **deploys** it: pull
`GET /api/v1/target-assignments?PageSize=5000` and filter for a task-type assignment
(`maintenanceType == 6`) whose `maintenanceIdentifier == "<taskId>"`. Note that `maintenanceIdentifier`
is shared across entity types, so filter on **type AND identifier** (a bare `identifier == 27` also
matches software id 27, etc.). A task only ever run ad-hoc (via the machine's "run task now") has
**no** target-assignment — those ad-hoc runs show up in the computer's maintenance-action history
with `assignmentId == 0`, and leave nothing persistent to remove.

## Testing a script or task against a real computer without deploying it

`POST /api/v1/scripts/run` (the script-editor "run"/debug endpoint, `RunScriptRequestBody`) is
the way to actually execute a script — saved or ad-hoc — against a specific computer and see the
real output, without creating a maintenance session or assigning anything. This is much more
useful than it sounds: you can pass **parameter overrides and variable overrides**, so you can
test a maintenance task's Set script exactly as it would run for real, including simulating
`$method` and the task's declared parameters.

```powershell
$runBody = @{
    script = @{
        id = 717                            # 0 for a fully ad-hoc, unsaved script body
        name = "Clear All Temp Folders"
        action = $scriptContent
        databaseType = "Local"               # or "Global"
        filterScriptMode = "Legacy"
        outputType = "Object"
        scriptCategory = "MaintenanceTaskSetter"
        scriptLanguage = "PowerShell"
        scriptExecutionContext = "System"
        timeout = 1800
        parameterOverrides = @{ DaysOld = "1"; TargetUser = "someuser" }   # task's declared params, by name
        variables = @{ method = "set" }                                    # standard helper vars, e.g. $method
    }
    computerId = 1257                       # target endpoint
    maintenanceTaskId = 724                 # optional - validates parameterOverrides against the task's declared params
    maintenanceTaskType = "Local"
} | ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/scripts/run" -Headers $headers -Body $runBody -TimeoutSec 300
```
All of `id, name, action, databaseType, filterScriptMode, id, name, outputType,
parameterOverrides, scriptCategory, scriptExecutionContext, scriptLanguage, variables` are
**required** in the nested `script` object even though many can just be empty
(`parameterOverrides = @{}`, `variables = @{}`). Response streams the script's console output as
plain text — read it back directly, no JSON envelope to unwrap.

**A simpler, safer alternative to hand-picking enum string names for the `script` object**: if
you're re-running an *existing* saved script, GET it first (`/api/v1/scripts/local/{id}`) and pass
its own `id, name, action, databaseType, filterScriptMode, outputType, scriptCategory,
scriptLanguage, scriptExecutionContext` straight through into the run payload unchanged. Those are
values the API itself already accepted and stored for that exact object, so there's zero risk of
picking the wrong enum int or string name — you're not deriving anything, just replaying what's
already known-valid. Only override `timeout`/`parameterOverrides`/`variables`.

**Hard ~120s gateway timeout on this endpoint — confirmed live, not a fluke.** `/api/v1/scripts/run`
is a synchronous streaming call: the HTTP response doesn't come back until the script finishes, and
this tenant's infrastructure kills that stream at almost exactly 2 minutes with a `504 Gateway
Timeout` / `stream timeout`, regardless of client-side `-TimeoutSec`. This is **not** related to a
caller's own VPN or network — confirmed by disconnecting/reconnecting VPN mid-debugging and seeing
the identical failure. For a script that genuinely needs longer than ~120s (e.g. one that itself
submits a job to another system and polls for that job's result), don't fight this — restructure the
call:
1. Have the script take a "submit and return immediately" mode (a parameter like
   `-WaitForResults $false`) instead of blocking on its own internal poll loop.
2. Fire it via `/scripts/run` with that override — returns in seconds since the script itself
   returns in seconds.
3. Poll the *actual downstream system* for the real result yourself, separately, using whatever
   API that system exposes — not through this ImmyBot endpoint, which only ever reports the
   console output of the run itself, not anything the script kicked off asynchronously.

**`maintenanceTaskId`/`maintenanceTaskType` are optional and purely for parameter validation** — per
the schema description: "so parameter overrides can be validated against the task's declared
parameters." Omit both entirely when running a plain software install/detection script that isn't
wired to a maintenance task; only `computerId` + the `script` object are required in that case.

**A `Software` item can have its own linked `maintenanceTaskId`** (a distinct field on the software
record, e.g. a post-install configuration step) — in that case, one `target-assignment` deploying
the software carries `taskParameterValues` covering **both** the software's own install-script
parameters *and* the linked maintenance task's parameters, all in one flat dictionary, even though
they're consumed by two completely different scripts. Don't assume a target-assignment's parameters
belong to only one script — check both the software record's own script IDs (`installScriptId`,
`detectionScriptId`, etc.) and its `maintenanceTaskId` to find every script that might read from
that same parameter set.

**Params baked into a local config file at install time are not "live" — re-running the install
script is the only way changes propagate.** If a software's install script writes any of its
parameters into a file on the endpoint (a `.env`, a registry value, anything read by a *different*
script that runs later), editing the target-assignment's parameter value in the UI/API does nothing
to an already-installed machine — the stale value stays on disk until the install script actually
runs again. This bit us twice in one session: once as a hard crash (an already-running background
process using old parameter-shaped code couldn't handle a new API contract and died silently), and
again as a stale API key that *looked* fixed (target-assignment updated correctly) but wasn't,
because the already-installed `.env` still had the pre-fix value. If a "fix" doesn't take effect,
check whether the consuming process needs a fresh install/restart to pick it up, before assuming the
parameter update itself failed.

Use this same mechanism to build **strictly read-only previews**: write a variant of the script
that only reports what it *would* do (no `Remove-Item`/mutating calls at all) and run it the same
way — safer than trusting `-WhatIf`/`ShouldProcess` plumbing on a script you haven't proven yet,
especially against a live client machine you don't want to risk.

## Looking up a computer by hostname

`GET /api/v1/computers` does **not** use the Sieve-style `Filters=` query param that
`/scripts` and `/software` use — passing `Filters=name==X` is silently ignored. It takes plain
query params instead: `name` (string, exact-ish match), `tenantId`, `orderByUpdatedDate`,
`pageSize` (default 25).
```powershell
Invoke-RestMethod -Uri "$immyBase/api/v1/computers?name=PCH-LT08&pageSize=5" -Headers $headers
# -> { id, name, tenant, tenantId, online, updatedDate, excludeFromMaintenance }
```
Don't assume every list endpoint shares the same query-param convention — check
`$sw.paths.'/api/v1/<route>'.get.parameters` for the specific route before guessing.

## Reading and updating a deployment's parameter overrides

A "deployment" in the UI (assigning a software/maintenance task to a target with specific
`taskParameterValues`, e.g. API keys or config baked into an onboarding task) is a **target
assignment** in the API, id shown in the UI URL. There is no plain `GET /api/v1/deployments/{id}`
— it 404s to the SPA shell (returns the `index.html`, not JSON). Two ways to actually read one:

- **Cheapest**: `GET /api/v1/maintenance-sessions/{sessionId}` for any session that ran under that
  deployment — `.sessionJobArgs.maintenanceItem.details.taskConfigurationDetails.taskParameterValues`
  has the exact param values that session ran with (`{ ParamName: { value, allowOverride,
  requiresOverride } }`). Caveat: this is a **historical snapshot** from whenever that session was
  created, not necessarily what the deployment is currently configured to. If the deployment's
  params were edited after that session ran, this will show you the stale pre-edit values — cross-
  check against a more recent session, or the UI, before trusting it as current.
- **`taskParameterValues` returns every field in cleartext, including `Password`-type params and API
  keys** — same shape as any other value, no masking. Before printing/logging a target-assignment
  response, filter out fields you know are sensitive (by name — `Password`, `*ApiKey`, `*Secret`,
  `*Token`, etc.) rather than dumping the whole object, exactly like the Railway `variables` query
  gotcha in `SKILL.md`. Confirmed live: an unfiltered `GET /api/v1/target-assignments/{id}` dump put
  a real Anthropic API key and a real account password straight into a chat transcript.
- To change values: `POST /api/v1/target-assignments/{deploymentId}/change-request`
  (`CreateTargetAssignmentChangeRequestRequest`, needs `deployments:manage_change_requests`
  permission). **This is not a partial patch** — the `payload` is a full
  `CreateLocalTargetAssignmentPayload` covering the assignment's target type/scope
  (`targetType`/`target`/`targetCategory`/`tenantId`), maintenance identity
  (`maintenanceIdentifier`/`maintenanceType`), and `taskParameterValues`, all required together.
  Getting scope fields wrong risks silently re-targeting the assignment rather than just updating
  its params. Don't attempt this from a values-only guess — confirm the assignment's full current
  shape (ideally by having someone pull it up in the UI, which shows the live values directly) before
  constructing the payload, or just make the edit through the UI instead.

## Other useful route families (seen in Swagger, not yet deep-dived)

- `/api/v1/dynamic-provider-types/global*` — integration/provider type definitions
- `/api/v1/target-assignments/global*` — what a piece of software/task is assigned/scoped to
- `/api/v1/media/global*` — icons/media assets, includes `upload` and `download-url`
- `/api/v1/provider-links/{id}/agents/*-install-script*` — generates the actual agent install script
  (bash/PowerShell) for a given provider link, with or without onboarding baked in
- `/api/v1/computers/{computerId}/detected-computer-software`, `/inventory-software/search-by-*` —
  what's actually installed on a machine per inventory data
