---
name: immybot
description: This skill should be used when working with ImmyBot — an RMM/MSP automation platform. Covers calling the ImmyBot REST API (OAuth2 client-credentials auth, global/local script and software catalogs, maintenance sessions), the end-to-end software install/deploy playbook (identify via primary user, catalog check, upload/analyze, ad-hoc + ongoing deployments), and writing ImmyBot PowerShell content (detection scripts, dynamic-version scripts, install/uninstall scripts, config/maintenance tasks with test-get-set, Invoke-ImmyCommand and other built-in Immy cmdlets). Trigger on "ImmyBot", "immy.bot", "push a script to Immy", "install software", "deploy software", "detection script", "dynamic versions script", "config task", "maintenance task", "Invoke-ImmyCommand", or RMM software-deployment automation.
version: 1.4.1
---

# ImmyBot

ImmyBot is an RMM automation platform (MSP-focused). Tenants run at `https://<subdomain>.immy.bot`.
Everything below was verified live against a real tenant's Swagger spec and API — not guessed from
general docs. See `references/` for the deep dives; this file is the map.

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
6. **Check Global and Local catalogs** for existing software. Reuse a good definition. **Writes stay
   Local** unless the operator explicitly wants Global community publish.
7. **If software is missing — always ask before fetching an installer:** *“Should I go look for the
   installer, or do you have a link I should use?”* Only hunt after they say so; if they give a
   link/path, upload from that. Then Local upload → analyze / fast-create so Immy can generate
   detection/install scripts.
8. **If generated scripts look generic or wrong — fix them** (silent args, detection, complex
   vendor installers often need this). Smoke-test one machine when practical.
9. **Ad-hoc now + ongoing deployment.** Run ad-hoc for the immediate need. Also ensure an **ongoing**
   deployment targets machine / user / tenant / group / tag as appropriate so **updates** flow when
   present and **new matching machines** get the software on the next applicable maintenance.
10. **Ad-hoc offline behavior — always ask:** Immy will ask what to do if the computer is off.
    Confirm and bake in **finish on connect** or **skip if offline**. Do not require the machine to
    be online before creating the ad-hoc.
11. **Reboot policy** — set what the job needs (e.g. **Force** = restart before and after). Ask if
    the ticket does not specify.

Keep primary users and person↔computer links current; the playbook depends on them.

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
  internally on an implicit `$method` variable (`"test"`, `"get"`, `"set"`). See the real Hibernation
  task example in `references/scripting-guide.md`. **For registry-only config tasks, don't hand-roll
  that `switch ($method)` — use the built-in `$method`-aware `RegistryShould-Be` / `HKCUShould-Be`
  helpers (Metascript context)**, which collapse test/get/set into a few declarative lines and
  auto-fan-out HKCU across all user profiles + the Default profile. See `references/scripting-guide.md`
  ("PREFER the built-in `*Should-Be` helpers" section).
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
