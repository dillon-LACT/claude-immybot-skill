---
name: immybot
description: This skill should be used when working with ImmyBot — an RMM/MSP automation platform. Covers calling the ImmyBot REST API (OAuth2 client-credentials auth, global/local script and software catalogs, maintenance sessions), and writing ImmyBot PowerShell content (detection scripts, dynamic-version scripts, install/uninstall scripts, config/maintenance tasks with test-get-set, Invoke-ImmyCommand and other built-in Immy cmdlets). Trigger on "ImmyBot", "immy.bot", "push a script to Immy", "detection script", "dynamic versions script", "config task", "maintenance task", "Invoke-ImmyCommand", or RMM software-deployment automation.
version: 1.3.0
---

# ImmyBot

ImmyBot is an RMM automation platform (MSP-focused). Tenants run at `https://<subdomain>.immy.bot`.
Everything below was verified live against a real tenant's Swagger spec and API — not guessed from
general docs. See `references/` for the deep dives; this file is the map.

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

**Discover the live API yourself** — every tenant's Swagger spec is authoritative and current, and this
tenant's spec was unusually well-documented (enum fields carry human-readable `x-enum-descriptions`):
```powershell
$sw = Invoke-RestMethod -Uri "$immyBase/swagger/v1/swagger.json" -Headers $headers
$sw.paths.PSObject.Properties.Name | Sort-Object          # every route
$sw.components.schemas.<SomeEnum>                          # enum meanings, in plain English
```

## Core concepts

- **Global vs Local catalog** (`DatabaseType`): Global = cross-tenant catalog shared by every tenant
  you manage; Local = this tenant only. Most entities (scripts, software, maintenance tasks, media)
  live in both `.../global` and `.../local` route trees with parallel shapes.
- **Scripts** are the atomic unit. A `Script` has: `name`, `action` (the PowerShell/CMD body — **field
  is `action`, not `scriptContent`**), `scriptLanguage`, `scriptExecutionContext`, `scriptCategory`,
  `timeout`, `outputType`.
- **Software** is a higher-level entity that *wires scripts together*: a detection method/script, an
  install/uninstall/upgrade/repair script, an optional test script, and optionally a dynamic-versions
  script + download-installer script instead of static versions.
- **Maintenance Tasks** (shown as "Config Tasks" in the UI when `isConfigurationTask` is true) wire up
  to three scripts — test / get / set — often all three pointing at *the same script*, which branches
  internally on an implicit `$method` variable (`"test"`, `"get"`, `"set"`). See the real Hibernation
  task example in `references/scripting-guide.md`.
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
43 built-in `*-Immy*` cmdlets, and three real working examples (detection, dynamic-versions, config
task) pulled live from a production tenant.

Read `references/api-reference.md` before calling the REST API — it has pagination/filter query params,
the script-push pattern, ad-hoc script execution, and maintenance-session rerun/status endpoints.

## Gotchas (bite people every time)

- Script body field is `action`, not `scriptContent`.
- List-style GET endpoints (e.g. `maintenance-sessions?computerId=X`) return the HTML SPA instead of
  JSON — only per-ID GETs (`/maintenance-sessions/{id}`) work through the API.
- Raw API JSON serializes enum fields (`scriptCategory`, `scriptExecutionContext`, etc.) as **integers**,
  and those integers do **not** reliably match the declaration order shown in the Swagger enum
  description. Don't compute an enum's integer from its position in the doc — fetch a real existing
  script/task of the category you want and copy its integer, or use the `Filters=field==N` query to
  probe (see `references/scripting-guide.md` for the mapping already confirmed on this tenant).
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
  pick Computers.** Real miss (Deltek, 2026-07): it was created as *Software (Configuration Task)*
  when it should have been *Runs Against: Computers*, so it didn't deploy/run as intended. When in
  doubt, choose Computers.
- `GET /api/v1/computers` uses plain `name`/`tenantId` query params, not the `Filters=` Sieve
  syntax that `/scripts` and `/software` use — check each route's own params in Swagger.
- `POST /api/v1/scripts/run` lets you test a script/task against a real computer with parameter
  and variable overrides (e.g. simulate `$method`) without deploying anything — see
  `references/api-reference.md`. For anything you haven't proven yet, especially against a live
  client machine, write a strictly read-only preview variant rather than trusting `-WhatIf`.
- Detection/version scripts commonly run `scriptExecutionContext = Metascript` and reach onto the
  endpoint via `Invoke-ImmyCommand { ... } -Verbose`, returning a version string (or `$null` if not
  installed) — not a boolean. See `Detect-GoogleChrome` (`Detect-Software "Chrome"`, a built-in helper)
  and the 1Password example in `references/scripting-guide.md` for both styles.
- **`POST /api/v1/scripts/run` has a hard ~120s gateway timeout** (confirmed live, `504 Gateway
  Timeout` / `stream timeout`, not caller VPN/network related) — it's a synchronous streaming call
  that blocks until the script finishes. For anything that legitimately runs longer, make the
  script itself return fast (a "submit and don't wait" mode) and poll the real downstream result
  separately, rather than fighting this endpoint's timeout. Full pattern in `references/api-reference.md`.
- **Run API calls from `pwsh` (PowerShell 7+), not legacy `powershell.exe` (5.1).** Confirmed live:
  `$scriptObject | ConvertTo-Json -Depth 20` hung indefinitely (60s+, no error, no timeout) in
  Windows PowerShell 5.1 on a trivial ~6KB flat object with zero nested structure — this wasn't a
  slow API, it never even reached the HTTP call. The identical script ran instantly in `pwsh`. If a
  GET-mutate-POST script "hangs" with no error, suspect this before suspecting the network — check
  which `powershell`/`pwsh` binary is actually running it before debugging anything else.
