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
