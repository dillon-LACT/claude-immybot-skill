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

**If this hangs with no error, check your PowerShell binary before anything else.** Legacy
`powershell.exe` (5.1) can hang inside `ConvertTo-Json -Depth 20` before the POST even fires, even
on small flat objects. Switching to `pwsh` (PowerShell 7+) fixes it. Don't waste time on
`-TimeoutSec`/try-catch/progress-bar workarounds first — confirm which binary is running.

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

## Software (local catalog) — read + patch detection

```
GET   /api/v1/software/local?Filters=...&Page=1&PageSize=50
GET   /api/v1/software/local/{softwareIdentifier}
PATCH /api/v1/software/local/{softwareIdentifier}   # UpdateLocalSoftwareRequestBody
```

Requires `software:manage`. PATCH is **replace-style for the fields you send** — GET the record,
rebuild `UpdateLocalSoftwareRequestBody` (string enums for `detectionMethod` /
`softwareTableNameSearchMode` / `upgradeStrategy` / license fields; `*ScriptType` as `Global`|`Local`
for each script id you keep), change only what you intend, PATCH, then GET read-back.

**Detection triage pattern (verified):** when sessions Install/Repair because software is “missing”
but inventory already shows the app:

1. Compare `softwareTableName` (+ search mode) to `GET /computers/{id}/detected-computer-software`
   `.softwareName`.
2. Prefer `softwareTableNameSearchMode = Regex` + anchored `(?i)^ExactName$` over `Contains` for
   short names (`Contains` `UNIFI` also hits **Chaos Unified Login**).
3. Validate with a **read-only** `scripts/run` Metascript preview (below) before fleet maintenance.
4. Pilot install with `run-immy-service-new` on one computer.

## Maintenance tasks (= "Config Tasks" in the UI)

```
GET /api/v1/maintenance-tasks/global?Page=1&PageSize=50
GET /api/v1/maintenance-tasks/global/{id}
GET /api/v1/maintenance-tasks/global/{id}/param-block-from-parameters
```

Returns `testScriptId`/`getScriptId`/`setScriptId` (+ `testEnabled`/`getEnabled`/`setEnabled`),
`maintenanceTaskCategory` (Computer/Tenant/Person — which target type the task runs against),
`isConfigurationTask`, `onboardingOnly`, `executeSerially`, `parameters[]`, supersession chain fields.

### "Runs Against" (task creation UI) → fields — get this right, it's unforgiving

The new-task form's **Runs Against** radio group is the same decision as these fields, and picking
wrong causes real breakage (see the SKILL.md gotcha; common miss = a normal task shipped as a
config task when it should have run against computers):

| UI "Runs Against"            | Fields set                                             | Use when |
| ---------------------------- | ------------------------------------------------------ | -------- |
| **Computers** (default)      | `maintenanceTaskCategory = Computer`, `isConfigurationTask = false` | Normal task that does work *on the endpoint* — registry/filesystem, enforcing settings, running a script on machines. UI hint: "This is a normal maintenance task." This is the right pick for almost everything. |
| **Cloud**                    | `maintenanceTaskCategory = Tenant`, `isConfigurationTask = false`   | Task targets the tenant/cloud, not a device. |
| **People**                   | `maintenanceTaskCategory = Person`, `isConfigurationTask = false`   | Task targets a person, not a device. |
| **Software (Configuration Task)** | `isConfigurationTask = true`, attached to a Software item      | *Only* when the task exists to inject runtime/parameter configuration into a specific software's install (parameterizing an installer), or to enforce that software's post-install config. More complex; don't reach for it just because your task relates to an app. |

**Why config tasks are a trap (from ImmyBot's docs):** a Configuration Task is **not** selectable on
the Edit Deployment page and **cannot be deployed on its own** — it only runs when its associated
Software is detected/installed on the machine (the maintenance session's "Has Configuration Task?"
branch runs *after* the software install/detect). Mark a task you meant to run everywhere as a config
task and it will silently never fire as a normal deployment. Config tasks exist to (a) pass command-
line parameters into a software's install script (leave the test/get/set scripts empty and just
declare parameters — Immy forwards them to the installer) and/or (b) enforce post-install config via
the test/get/set pattern.

**Rule of thumb:** unless the task's whole purpose is to inject runtime parameters for an installer,
choose **Computers**. When in doubt, Computers.

## Running an ad-hoc script on a specific machine (not via catalog)

```powershell
$payload = [ordered]@{
    Script = [ordered]@{
        name   = "my-script-name"   # required
        action = $scriptContent     # PS code string
        scriptLanguage         = 2  # 2 = PowerShell
        scriptExecutionContext = 2  # Metascript (confirmed) when using Invoke-ImmyCommand
        timeout = 90
    }
    body       = @{}
    computerId = <computerId>
} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/scripts/run" -Headers $headers -Body $payload
```

For **detection previews**, keep the script strictly read-only: Metascript + `Invoke-ImmyCommand`
that enumerates uninstall keys / applies the same Regex as `softwareTableName`, returns JSON like
`WouldDetectRegex` / `ExactMatches` / `NearMissExcluded`. Do **not** call installers from
`scripts/run` when the ask is “preview detection.”

## Ad-hoc software install / detection-only via `run-immy-service-new`

```powershell
$sessionGroupId = [guid]::NewGuid().ToString()
$body = [ordered]@{
    computers = @(@{ computerId = <computerId> })
    maintenanceParams = [ordered]@{
        maintenanceIdentifier = '<softwareId>'   # string
        maintenanceType       = 'LocalSoftware'  # or GlobalSoftware
        desiredSoftwareState  = 'LatestVersion'  # 5
        repair                = $false
    }
    offlineBehavior                    = 'ApplyOnConnect'  # or Skip
    rebootPreference                   = 'Suppress'
    suppressRebootsDuringBusinessHours = $true   # set false when Force reboot must happen in-window
    fullMaintenance                    = $false
    detectionOnly                      = $false  # true = evaluate only, no install/set
    inventoryOnly                      = $false
    resolutionOnly                     = $false
    cacheOnly                          = $false  # true = download only, no execute
    useWinningDeployment               = $false
    sessionGroupId                     = $sessionGroupId
    # omit updateTime => run immediately
} | ConvertTo-Json -Depth 6

# Background endpoint often returns 202 with empty body when sessionGroupId is set
Invoke-WebRequest -Method Post -Uri "$immyBase/api/v1/run-immy-service-new" `
    -Headers $headers -Body $body -ContentType 'application/json'
```

**Phase flags (mutually useful for “preview” asks):**

| Flag | Effect |
|---|---|
| `detectionOnly` | Run detection / decide actions — **no** installs, removals, or task sets |
| `inventoryOnly` | Inventory capture only |
| `resolutionOnly` | Preview winning-deployment resolution without applying |
| `cacheOnly` | Download/stage payloads without executing |

After **202**, find the session: `/api/v1/maintenance-sessions/dx` filtered by `computerId`, sort
newest `createdDate`, then poll `GET /maintenance-sessions/{id}` (`sessionStatus`:
`0=Passed`, `1=Running`, `2=Failed`) and `/maintenance-actions/dx` for that
`maintenanceSessionId`. Action `result` `1=Success`; `desiredSoftwareState` `5=LatestVersion`.

## Maintenance sessions

```powershell
# Rerun — key is "sessionIds" (array), NOT "maintenanceSessionId". Returns 204 No Content.
Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/maintenance-sessions/rerun" -Headers $headers -Body (@{ sessionIds = @(<sessionId>) } | ConvertTo-Json)

# Status
$s = Invoke-RestMethod -Uri "$immyBase/api/v1/maintenance-sessions/<sessionId>" -Headers $headers
# sessionStatus / executionStageStatus: 0=Passed, 1=Running, 2=Failed

# Actions for one session (OR across session IDs is NOT supported — one call per id)
$filter = [uri]::EscapeDataString('[["maintenanceSessionId","=",1322918]]')
$acts = Invoke-RestMethod -Uri "$immyBase/api/v1/maintenance-actions/dx?skip=0&take=500&requireTotalCount=false&filter=$filter" -Headers $headers
# result: 0=Pending, 1=Success, 2=Failed, 3=Cancelled, 4=Indeterminable, 5=Resolved
# Failures often set resultReasonMessage (e.g. script timeout, "No version of X was found")

# Person for follow-up @mentions — list /computers?tenantId= often omits primaryPerson; use per-ID:
$c = Invoke-RestMethod -Uri "$immyBase/api/v1/computers/<computerId>" -Headers $headers
# $c.primaryPerson.displayName / emailAddress
```

List-style maintenance-session GETs (e.g. `?computerId=X`) return the HTML SPA, not JSON — only
per-ID GETs work through the API.

**Post-deploy follow-up:** after timed/overnight installs, always re-check these endpoints and
customer-@mention on the Thread ticket from live Success/Failed (see SKILL.md
“Post-session follow-up”). Prefer recorded session IDs over wide `/dx` hunts.


### DevExtreme `/dx` grids — how to query them at scale

The `*/dx` endpoints are DevExtreme DataSource endpoints. They take JSON query params
(URL-encode each): `filter`, `sort`, `select`, `group`, `groupSummary`, `totalSummary`,
`skip`, `take`, `requireTotalCount`, `requireGroupCount`. Hard-won rules from probing
`/api/v1/maintenance-actions/dx` on busy tenants:

- **`requireTotalCount=true` is the expensive/timeout part, NOT the date filter.** It
  forces a full `COUNT(*)` over the filtered set. Narrow windows (hour) are cheap; day+
  windows can take tens of seconds or time out. The row fetch itself is usually fast.
  **Never send `requireTotalCount=true` on a wide window** — page with
  `requireTotalCount=false` and stop on a short page.
- **Wide + sorted raw fetches also choke.** A week-wide `sort` + `take=1000` (no count)
  can still time out — sorting hundreds of thousands of rows to return the first page is
  too much. Keep raw windows narrow (hour/day), or aggregate server-side (below).
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

`maintenanceActions` enum ints (declaration order, verified against live data):
- `actionType`: 0=NoAction, 1=Install, 2=Update, 3=Uninstall, 4=Download, 5=Reinstall,
  6=Downgrade, 7=Undetermined, 8=TaskEnforce, 9=TaskMonitor, 10=TaskAudit
- `result`: 0=Pending, 1=Success, 2=Failed, 3=Cancelled, 4=Indeterminable, 5=Resolved

### Reporting on maintenance actions by week

**Preferred: action-first, day-windowed, with NoAction filtered server-side.** Most action rows
are often `actionType=0` (NoAction — pass-only checks). Excluding them server-side usually
collapses volume enough that a whole day fits in one call (~7 calls for a full week), vs one
call per session for the session-first pattern below.

```powershell
# one call per day; loop the 7 days of the week. createdDateUTC is UTC.
$dayFilter = [uri]::EscapeDataString(
  '[["createdDateUTC",">=","01/01/2026 00:00:00"],"and",["createdDateUTC","<","01/02/2026 00:00:00"],"and",["actionType","<>",0]]'
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

**Hard ~120s gateway timeout on this endpoint.** `/api/v1/scripts/run` is a synchronous streaming
call: the HTTP response doesn't come back until the script finishes, and the gateway commonly kills
that stream at almost exactly 2 minutes with a `504 Gateway Timeout` / `stream timeout`, regardless
of client-side `-TimeoutSec`. For a script that genuinely needs longer than ~120s (e.g. one that
itself submits a job to another system and polls for that job's result), don't fight this —
restructure the call:
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
Invoke-RestMethod -Uri "$immyBase/api/v1/computers?name=EXAMPLE-LT01&pageSize=5" -Headers $headers
# -> { id, name, tenant, tenantId, online, updatedDate, excludeFromMaintenance }
```
`GET /api/v1/computers/{id}` uses **`computerName`** (not `name`) plus `isOnline`, `tenantId`,
`primaryPerson`, etc. The unfiltered computers list is often **not a complete fleet dump** — for
“all online boxes in tenant X,” Thread MCP `search_immybot_computers` (with `tenant_id` /
`online`) is more reliable than assuming `GET /computers` returned everyone.

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
  `*Token`, etc.) rather than dumping the whole object. Unfiltered dumps have been observed to leak
  real secrets into chat transcripts.
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

## Tenants, enroll scripts, inventory, and tenant-scoped deployments

Deep playbook (gates, RNS sticky facts, evidence labels):
`references/tenant-onboarding-and-deployments.md`.

### Create + activate tenant

```powershell
# POST /api/v1/tenants  (CreateTenantRequestBody)
$body = @{
  name = 'Customer Name (CODE)'
  slug = 'CODE'
  ownerTenantId = 1          # Logic TCG MSP
  isMsp = $false
  principalId = $null        # set only when linking Azure AD
} | ConvertTo-Json
$tenant = Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/tenants" -Headers $headers -Body $body

# PATCH /api/v1/tenants/activate/{id}  (POST returns 405)
Invoke-RestMethod -Method Patch -Uri "$immyBase/api/v1/tenants/activate/$($tenant.id)" -Headers $headers | Out-Null
```

### Agent install script without auto-onboarding (ImmyBot Agent provider)

LogicTCG provider-link id **2** (`ImmyBot Agent`) does **not** support
`.../powershell-install-script` (NotSupported). Use the with-onboarding route and set
`automaticallyOnboard = false`. Never log or commit the `.script` body.

```powershell
$payload = @{
  platform = 'Windows'
  targetExternalClientId = "$($tenant.id)"   # string; matches agent client externalClientId
  onboardingOptions = @{
    automaticallyOnboard = $false
    onboardingSessionSendFollowUpEmail = $false
    isDevLab = $false
  }
} | ConvertTo-Json -Depth 5
$scriptObj = Invoke-RestMethod -Method Post `
  -Uri "$immyBase/api/v1/provider-links/2/agents/powershell-install-script-with-onboarding" `
  -Headers $headers -Body $payload
# $scriptObj.script  -> operator-local file only
```

Also useful: `POST .../clients/link-to-new-tenant` (`externalClientId`, optional `tenantName`) and
`POST .../clients/link-to-tenant` (`clientIds[]`, `tenantId`).

### Inventory for a tenant

```powershell
# Prefer existing inventory before any refresh job
$inv = Invoke-RestMethod -Uri "$immyBase/api/v1/tenants/software-from-inventory/$tenantId" -Headers $headers
# rows: displayName, globalSoftwareId/Name/Version, computerId/Name, person*, dateDetectedUtc
```

**Gotcha:** `GET /api/v1/computers?tenantId=X` may ignore the filter — always filter client-side on
`.tenantId`.

### Create a tenant-scoped software deployment

`POST /api/v1/target-assignments` (`CreateLocalTargetAssignmentPayload`). Existing LogicTCG
tenant-wide software rows commonly use `targetType = AllForTenant` (21) + `tenantId`:

```powershell
$assign = @{
  maintenanceIdentifier = '1234'            # software id as string
  maintenanceType       = 'GlobalSoftware'  # or LocalSoftware
  targetType            = 'AllForTenant'
  targetCategory        = 'Computer'
  tenantId              = $tenantId
  desiredSoftwareState  = 'UpdateIfFound'   # 7 = update if found; 'LatestVersion'/5 = install+keep current
  targetEnforcement     = 'Required'
  onboardingOnly        = $false
  excluded              = $false
  propagateToChildTenants = $false
} | ConvertTo-Json
$created = Invoke-RestMethod -Method Post -Uri "$immyBase/api/v1/target-assignments" `
  -Headers $headers -Body $assign
# Always GET read-back and confirm tenantId / desiredSoftwareState / onboardingOnly
```

`DesiredSoftwareState`: `LatestVersion=5`, `UpdateIfFound=7` (also `NotPresent=1`, `AnyVersion=2`,
`NoAction=6`, …). Do not treat “keep updated” and “install if found” as interchangeable without
observing the saved UI/API fields.

## Other useful route families (seen in Swagger, not yet deep-dived)

- `/api/v1/dynamic-provider-types/global*` — integration/provider type definitions
- `/api/v1/target-assignments/global*` — global catalog assignments / overrides
- `/api/v1/media/global*` — icons/media assets, includes `upload` and `download-url`
- `/api/v1/computers/{computerId}/detected-computer-software`, `/computers/inventory-software/search-by-*` —
  per-computer / search inventory helpers (tenant rollup is `tenants/software-from-inventory/{id}`)
