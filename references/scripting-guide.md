# ImmyBot Scripting Guide

Everything here was verified against live ImmyBot Swagger, real `Get-Help -Full` output for the
built-in cmdlets (via the ad-hoc-metascript introspection trick — see `api-reference.md`), and
script bodies from the global catalog. Not paraphrased docs.

## Script fields

A `Script` record: `name`, `action` (the actual PS/CMD body), `scriptLanguage`, `timeout`,
`scriptExecutionContext`, `scriptCategory`, `outputType`, `filterScriptMode`.

### ScriptLanguage
`CommandLine = 1`, `PowerShell = 2`. (Confirmed directly in the enum description — this one's stable.)

### ScriptExecutionContext
Swagger documents four string names (`System`, `CurrentUser`, `Metascript`, `CloudScript`) — but
**raw API JSON often returns integers that do not reliably match declaration order.** Confirmed
live samples:

| Integer (API) | Typical use (observed) |
|---|---|
| `0` | `System` — install/uninstall version-action scripts on the endpoint |
| `2` | `Metascript` — Function helpers, most DownloadInstaller scripts, many detections |
| `4` | **Every Global DynamicVersions script sampled (n=500)** — copy this when creating DV scripts |

`4` is **outside** Swagger's documented 0–3 string enum. Treat it as the required context for
Dynamic Versions discovery (backend version-resolution host). **Don't invent the integer — copy
from an existing script of the same category.**

| Context name | Meaning |
|---|---|
| `System` | Runs on the target computer under the local SYSTEM account |
| `CurrentUser` | Runs on the target computer in the interactive user's session |
| `Metascript` | Runs in the ImmyBot backend's PowerShell host — does *not* touch the endpoint directly; use `Invoke-ImmyCommand` from here to reach the endpoint |
| `CloudScript` | Runs in the backend sandbox with no agent involvement at all |

### ScriptCategory
Determines what variables/behavior are available to the script. **Confirmed real integer values** (by
fetching live examples and cross-checking against the Swagger description text — the *declaration
order* in Swagger does NOT match these integers, so don't derive them yourself):

| Int | Category | Meaning |
|---|---|---|
| 0 | `SoftwareDetection` | Detects whether software is installed |
| 1 | `Integration` | Defines a dynamic integration provider type + operations (inferred by elimination, not directly sampled) |
| 2 | `SoftwareVersionAction` | Per-version action on software: install / uninstall / upgrade / test |
| 3 | `MaintenanceTaskSetter` | A config/maintenance task's test/get/set step (confirmed via the Hibernation task, see below) |
| 4 | `MetascriptDeploymentTarget` | Metascript that resolves which computers a maintenance item targets |
| 5 | `FilterScriptDeploymentTarget` | Filter script that resolves computer targeting |
| 6 | `DeviceInventory` | Inventory-collection script |
| 7 | `Function` | Helper function loaded into the Metascript runspace for other scripts to call |
| 8 | `ImmySystem` | Built-in system script, read-only, protected from deletion |
| 9 | `DynamicVersions` | Dynamically discovers software versions from an external source (confirmed via global-catalog examples) |
| 10 | `DownloadInstaller` | Downloads an installer payload for a dynamic version (confirmed via global-catalog examples) |
| 11 | `Module` | PowerShell module imported into the Metascript runspace |
| 12 | `Preflight` | Gate script that runs before a maintenance session (confirmed via "Is Machine Fully Booted") |

If you need a category not listed above with full confidence, query it live:
`GET /api/v1/scripts/global?Filters=scriptCategory==N&PageSize=1` and read the returned script's name —
cheap way to confirm before you write anything that depends on it.

### ScriptOutputType
`Object = 0` (UI shows a property grid) or `Table` (UI shows a tabular grid, for scripts that return a
collection).

### FilterScriptMode
`Legacy = 0` (returns `PSComputer[]`, no caching) or `Optimized = 1` (returns `int[]`, cached — prefer
this for new filter scripts).

## Invoke-ImmyCommand — the Metascript↔endpoint bridge

This is the cmdlet that actually reaches out to the target computer from Metascript-context code.
Verified signature (`Get-Help -Full`, run live against the tenant):

```
Invoke-ImmyCommand [-ScriptBlock] <scriptblock> [-ArgumentList <ArrayList>] [-Computer <PSComputer[]>]
  [-ContextString <string>] [-Timeout <int>] [-ConnectTimeout <int>]
  [-AgentConnectionWaitTimeout <timespan>] [-Parallel] [-DisableConnectTimeoutWarnings]
  [-IncludeLocals] [-ScriptType {CommandLine | PowerShell}] [-ScriptName <string>]
  [-CircuitBreakerPolicy {Unrestricted | BypassEphemeral}]
```

- `-ScriptBlock` (positional 0, required) — the code that runs *on the endpoint*.
- `-ArgumentList` — positional args into the scriptblock.
- `-Computer <PSComputer[]>` — target(s); accepts pipeline input. Omit to target the computer already
  in context.
- `-ContextString` — `"System"` or `"User"`. Running as `"User"` with nobody logged in skips the command
  unless you also set `TerminateFromNoLoggedOnUser`.
- `-Timeout <int>` — seconds to allow the scriptblock to run before giving up.
- `-Parallel` — when piping multiple computers in, run on all of them simultaneously (capped at 100).
- `-IncludeLocals` — pull parent-runspace variables into the remote scriptblock's scope.
- Bridge variables from Metascript scope into the remote scriptblock with `$using:varName`, exactly
  like native `Invoke-Command`.
- Returns `System.String` per the cmdlet metadata, but in practice whatever the scriptblock's last
  expression emits comes back — treat it like a normal PowerShell return value.

```powershell
# Real pattern, from a working install script:
Invoke-ImmyCommand {
    $UserPackage = Get-AppxPackage -AllUsers | Where-Object { $_.PackageFamilyName -eq $using:targetPackageFamilyName }
    if ($UserPackage) { return [String]$UserPackage.Version } else { return $null }
} -Verbose
```

## Other built-in Immy cmdlets (verified via live `Get-Help -Full`)

- **Get-ImmyComputer** `[-TargetGroupFilter {All|Servers|Workstations|PortableDevices|WorkstationsAndPortableDevices|DomainControllers|PrimaryDomainControllers}] [-InventoryKeys {Antivirus|DuplicateComputerResolver|ExternalHostnames|ExternalIp|InternalIp|LoggedOnUser|LoggedOnUserSID|LogicalDisks|NetworkAdapters|Partitions|PhysicalDisks|PhysicalMemory|Processes|RebootPending|Software|WindowsSystemInfo}] [-DeviceId <guid>] [-UseParentTenant] [-IncludeOffline] [-OnboardingOnly] [-IncludeTags]` — the main way to look up computer(s) and pull cached inventory data without touching the endpoint.
- **Stop-ImmySession** `[-PendingMessage <string>] [-SuccessMessage <string>] [-FailureMessage <string>]` — halts the current maintenance session/action from within a script (e.g. a preflight gate).
- **Set-ImmySession** `[-RebootPreference {Normal|Suppress|Prompt|Force}]` (required) — controls reboot behavior for the current session.
- **Wait-ImmyComputer** `[-Computer <PSComputer[]>] [-Timeout <timespan>]` (default timeout 30 min) — blocks until a computer (e.g. one that just rebooted) comes back online.
- **New-ImmyTempFile** `[-Computer] [-BasePath] [-BaseName] [-Extension] [-Value] [-FileName] [-AvoidWindowsTemp] [-Everyone]` — creates a temp file, optionally on a remote computer, optionally seeded with `-Value`.
- **Set-ImmyMaintenanceActionProgress** `[-ManualProgressPercentComplete <decimal>] [-ManualProgressStatus <string>]` — updates the progress bar/status text shown in the UI for a long-running action.
- **Send-ImmyEmail** `[-Subject] <string> [-Body] <string> [[-To] <List[string]>] [[-Bcc] <List[string]>]`.

Full list of all 43 `*Immy*` built-ins (names only — introspect any of them the same way if you need
params):
`Add-ImmyMaintenanceActionChild`, `Add-ImmyMaintenanceActionDependency`, `Add-ImmyMaintenanceActionDependent`,
`CompareTo-ImmyBotVersion`, `Connect-ImmyAzureAD`, `Get-ImmyAADJoinRefreshToken`, `Get-ImmyADComputer`,
`Get-ImmyAuthToken`, `Get-ImmyAzureADUser`, `Get-ImmyAzureAuthHeader`, `Get-ImmyBlob`,
`Get-ImmyBotAgentFileVersion`, `Get-ImmybotAgentVersion`, `Get-ImmyBotVersion`, `Get-ImmyComputer`,
`Get-ImmyComputerAzureADDeviceId`, `Get-ImmyDomainController`, `Get-ImmyExternalIP`,
`Get-ImmyMaintenanceActionChildren`, `Get-ImmySoftwareMicrosoftServicePlans`, `Get-OfflineImmyComputer`,
`Invoke-ImmyCommand`, `Invoke-ImmyDomainController`, `Merge-ImmyComputers`, `New-ImmyTempFile`,
`New-ImmyTempFolder`, `New-ImmyUploadSasUri`, `New-ImmyWebHook`, `Send-ImmyDataEmail`, `Send-ImmyEmail`,
`Set-ImmyBlob`, `Set-ImmyDeviceId`, `Set-ImmyMaintenanceActionProgress`,
`Set-ImmyPrimaryPersonFromIntune`, `Set-ImmyPrimaryUser`, `Set-ImmySession`, `Set-PrimaryUserFromImmy`,
`Stop-ImmySession`, `Test-ImmyDeviceAssociation`, `Upload-ImmyFile`, `Upload-ImmyFileAsCopy`,
`Wait-ImmyComputer`, `Wait-ImmyWebHook`.

There's also a built-in `Detect-Software "<name>"` helper (not Immy-prefixed) used for simple
software-table-based detection — see the Google Chrome example below.

## Software entity — the fields that matter

`GET /api/v1/software/global/{id}` (and the parallel `/software/local/{id}`) returns (trimmed to the
load-bearing fields):

- `detectionMethod`: `SoftwareTable` (match installed-programs table by name — pairs with
  `softwareTableName` + `softwareTableNameSearchMode`) | `CustomDetectionScript` (pairs with
  `detectionScriptId`) | `UpgradeCode` | `ProductCode` (MSI-based matching).
- `softwareTableName` + `softwareTableNameSearchMode` when using `SoftwareTable`:
  - Modes: `Contains` (0) | `Regex` (1) | `Traditional` (2).
  - **`Contains` is substring match** — dangerous for short names. Verified: pattern `UNIFI` also
    matches **Chaos Unified Login** because `Unified` contains `unifi`.
  - For exact display-name detection prefer **`Regex`** with an anchored, case-insensitive pattern,
    e.g. `(?i)^UNIFI$`. That still matches `UNIFI` / `Unifi`, and excludes Chaos Unified Login.
  - The table name must match what inventory actually stores (`detected-computer-software`
    `.softwareName`). A stale wrong name (verified: detecting `Content Catalog` while inventory
    shows `UNIFI`) produces fleet-wide “missing → install/repair” failures even when the app is
    present. Inventory rows also won’t link to the software id until the name/mode lines up.
- `useDynamicVersions` (bool) + `dynamicVersionsScriptId` — when true, versions come from running a
  script instead of being declared statically; `downloadInstallerScriptId` fetches the actual
  installer payload for a resolved dynamic version.
- `installScriptId`, `uninstallScriptId` — the version-action scripts (`ScriptCategory =
  SoftwareVersionAction`).
- `testRequired` + `testScriptId` + `testFailedError` — optional post-install verification.
- `upgradeStrategy`: `None | UninstallInstall | InstallOver | UpgradeScript` (+ `upgradeScriptId` for
  the last).
- `repairType`: `None | UninstallInstall | InstallOver | CustomScript` (+ `repairScriptId`).
- `postInstallScriptId` / `postUninstallScriptId` — optional scripts after a successful action.
- `licenseRequirement`: `None | Required | Optional`, `licenseType`: `None | LicenseFile | Key`.
- `rebootNeeded` (bool), `installOrder` (int, sequences multi-software deployments).

**Update local software detection:** `PATCH /api/v1/software/local/{softwareIdentifier}` with
`UpdateLocalSoftwareRequestBody` (see `api-reference.md`). Treat it as replace-style for the fields
you send — rebuild from a fresh GET, change `softwareTableName` / `softwareTableNameSearchMode`
(and keep script ids + `*ScriptType` `Global`/`Local`). Always GET read-back before declaring fixed.

## Maintenance Task (= "Config Task") — test/get/set pattern

`isConfigurationTask` (bool) is the UI discriminator for "config task" vs regular maintenance task.
`maintenanceTaskCategory`: `Computer | Tenant | Person` — what kind of target the task runs against.
`testEnabled`/`getEnabled`/`setEnabled` gate whether `testScriptId`/`getScriptId`/`setScriptId` run.
`useScriptParamBlock` (bool) — when true, parameters bind via the set script's own `param(...)` block
instead of the task's declared `parameters[]`. `executeSerially` — child actions run one at a time
instead of in parallel. `onboardingOnly` / `ignoreDuringAutomaticOnboarding` control when the task fires.

**Real confirmed example** — the built-in "Hibernation" task: all three of `testScriptId`,
`getScriptId`, `setScriptId` point at the *same* script (id 844, `scriptCategory = 3` =
`MaintenanceTaskSetter`), which branches on an implicit `$method` variable:

```powershell
Function Get-HibernationEnabled {
    return ($null -eq (powercfg /a | ?{ $_.Contains('Hibernation has not been enabled.') }))
}

switch ($method) {
    "get" {
        if (Get-HibernationEnabled) { return "Hibernation Enabled" } else { return "Hibernation Disabled" }
    }
    "set" {
        if ($EnableHibernation -eq $true) { powercfg /hibernate on } else { powercfg /hibernate off }
        return
    }
    "test" {
        return ((Get-HibernationEnabled) -eq $EnableHibernation)
    }
}
```

`$EnableHibernation` here is a task parameter bound in from `parameters[]` (or the param block, if
`useScriptParamBlock` is set). This one-script-three-methods pattern is the standard, idiomatic way to
write a config task — write it this way unless you have a reason not to.

## Detection scripts — two real working styles

**Style 1 — built-in table detection** (simplest, `scriptCategory = SoftwareDetection`,
`scriptExecutionContext = Metascript`):
```powershell
Detect-Software "Chrome"
```

**Style 2 — custom detection via Invoke-ImmyCommand** (when the software isn't in the installed-programs
table, e.g. per-user AppX packages). Real working example from a production ImmyBot install:
```powershell
$targetPackageFamilyName = "Agilebits.1Password_amwd9z03whsfe"
try {
    Invoke-ImmyCommand {
        $UserPackage = Get-AppxPackage -AllUsers | Where-Object { $_.PackageFamilyName -eq $using:targetPackageFamilyName }
        if ($UserPackage) {
            return [String]$UserPackage.Version
        } else {
            return $null
        }
    } -Verbose
} catch {
    Write-Warning "An error occured while attempting to find installation."
    return $null
}
```
Detection scripts return a **version string** if installed, `$null` if not — not a boolean.

## Dynamic Versions playbook

Verified against **200 Global `scriptCategory=9` scripts** (plus strategy sanity on 500 total) and
the live Function helpers they call. Official docs say return objects with at least Version + URL;
the Global catalog almost always does that via helpers that wrap `New-DynamicVersion`.

### What Dynamic Versions are for

On a Software record, set `useDynamicVersions = true` and point `dynamicVersionsScriptId` at a
category-9 script. At resolve time Immy runs that script to discover available versions (and their
download URLs) instead of relying on statically uploaded `softwareVersions`. Pair with
`downloadInstallerScriptId` when the default download path is insufficient (auth, UA spoofing,
endpoint-side fetch). Prefer an existing **Global** title that already has a working DV script
before authoring a Local one.

### Fields to set on the script (copy from a live DV script)

| Field | Observed value (Global sample) |
|---|---|
| `scriptCategory` | `9` (`DynamicVersions`) |
| `scriptExecutionContext` | **`4`** (all 500/500 sampled — **not** Metascript `2`) |
| `scriptLanguage` | `2` (`PowerShell`) |
| `outputType` | `0` (`Object`) |
| `timeout` | usually null/default (~86%); bump to `30`–`60` for redirects/scrapes; `300` only for heavy work |

Body field is still `action`. Most scripts are short: ~70% under 300 chars (one helper call).

### Decision tree — pick the thinnest helper that fits

1. **Stable direct installer URL** (version is in the file / PE metadata) →
   `Get-DynamicVersionFromInstallerURL` (~42% of first 200)
2. **Vendor HTML/JSON page with regex-able links** →
   `Get-DynamicVersionsFromURL -URL … -VersionsURLPattern '…'` (~23%)
3. **GitHub Releases assets** →
   `Get-DynamicVersionsFromGitHubUrl -GitHubReleasesUrl … -VersionsPattern '…'` (~12%)
4. **aka.ms / fwlink / “latest” URL that 302s into a versioned filename** →
   `Get-DynamicVersionFromUriRedirect` (or `Get-RedirectedUri` + `Get-DynamicVersions`)
5. **SourceForge** → `Get-DynamicVersionsFromSourceForgeUrl`
6. **MSIX `.appinstaller` XML** → `Get-DynamicVersionFromAppinstallerURL`
7. **Microsoft download LinkID / go.microsoft.com** → `Get-DynamicVersionFromMicrosoftLinkId`
8. **Vendor-specific** (rare) → `Get-DynamicVersionsFromDell`, `Get-DynamicVersionsFromBrother`, etc.
9. **Only if none of the above fit** → scrape yourself, then `New-DynamicVersion` + return envelope

Browse helpers: `GET /api/v1/scripts/global?Filters=scriptCategory==7&PageSize=50` (or
`/scripts/global/names` and filter names starting with `Get-Dynamic` / `New-Dynamic`).

### Return envelope (required shape)

Helpers return (and custom scripts should return) a single object:

```powershell
New-Object PSObject -Property @{
    Versions = @(
        New-DynamicVersion -Uri $Uri -Version $Version -FileName $FileName
        # optional: -Architecture X64 -PackageHash $md5 -PackageType Executable|Zip -DependsOnVersion $v
    )
}
```

`New-DynamicVersion` params (Function id in Global catalog): `-Uri` (alias `-URL`), mandatory
`-Version` (`[Version]`), optional `-FileName`, `-PackageHash` (MD5; alias `-FileHash`),
`-PackageType` (`Executable`|`Zip`), `-Architecture` (`X86`|`X64`|`AMD64`|`ARM64`|`i386`),
`-DependsOnVersion`, `-RelativeCacheSourcePath`. Filename is inferred from the URI when omitted.
**~65% of Global DV scripts are a bare helper call** — the helper emits this envelope for you; no
explicit `return` needed.

### Named capture groups (regex helpers)

For `Get-DynamicVersionsFromURL` / `Get-DynamicVersions` / GitHub / SourceForge patterns, use
**named** groups. Most common in the wild:

| Group | Role |
|---|---|
| `Version` | **Required** — parsed as `[Version]` |
| `Uri` / `RelativeUri` | Download URL (relative URIs rewritten against the page URL) |
| `FileName` | Installer filename |
| `Architecture` / `Bitness` | Arch filter (`x64`/`x86`/`64`/…) |
| `RelativeCacheSourcePath` | Path inside a zip package |

Example URL scrape:
```powershell
Get-DynamicVersionsFromURL `
    -URL "https://iriun.com" `
    -VersionsURLPattern '(?<Uri>https://cdn.example/(?<FileName>App-(?<Version>\d+\.\d+(?:\.\d+){0,2}).exe))'
```

Example GitHub:
```powershell
Get-DynamicVersionsFromGitHubUrl `
    -GitHubReleasesUrl 'https://github.com/Zettlr/Zettlr/releases' `
    -VersionsPattern "Zettlr-(?<Version>[\d\.]+)-x64.exe"
```

Example installer URL (no regex):
```powershell
Get-DynamicVersionFromInstallerURL "https://secure.example.com/product.msi"
```

Example redirect “latest” link:
```powershell
Get-DynamicVersionFromUriRedirect "https://aka.ms/cosmosdb-emulator"
```

### Helper parameter cheat-sheet (live Function scripts)

- **`Get-DynamicVersionFromInstallerURL`** — `-URL` (mandatory), `-VersionIfNull`, `-FileNameIfNull`,
  `-ResolveRedirect`, `-Force`. Reads version from the installer when possible.
- **`Get-DynamicVersionsFromURL`** — `-URL`, `-VersionsURLPattern` (mandatory); optional
  `-VersionURLRewrite`, `-VersionRewrite`, `-FileNameRewrite`, `-SortGroup`/`-SortOrder` (default
  Version/Descending), `-VersionCountLimit` (default 10), `-PreventVersionsWithBadUri`,
  `-RelativeCacheSourcePath`, `-TTL` (default 1 day cache), `-UserAgent`, `-Headers`.
- **`Get-DynamicVersions`** — same rewrite/sort/limit knobs, but `-InputString` + `-VersionsPattern`
  (parse an already-fetched string / redirected URL).
- **`Get-DynamicVersionsFromGitHubUrl`** — `-GitHubReleasesUrl`, `-VersionsPattern`; optional
  `-DynamicVersionFilter` (scriptblock), `-VersionsField` (default `browser_download_url`),
  `-IncludedParentFields`, `-VersionRewrite`/`-FileNameRewrite`/`-UrlRewrite`, `-PerPage`,
  `-LatestRelease`.
- **`Get-DynamicVersionsFromSourceForgeUrl`** — `-SourceForgeProjectName`, `-VersionsPattern`;
  optional filters/rewrites; can populate `PackageHash` from SourceForge `md5sum`.
- **`Get-DynamicVersionFromUriRedirect`** — `-Uri`, optional `-Pattern` (default version-in-URL),
  `-MaximumRedirection`, `-Method` HEAD|GET.
- **`Get-RedirectedUri`** — resolve a 302/307 to the final URL (supports `-UserAgent` / method
  fallback). Compose with `Get-DynamicVersions` when you need a custom pattern on the final URL.
- **`Invoke-CommandCached`** — `-CacheKey`, `-ScriptBlock`, optional `-TTL` (default 1 day),
  `-ForceUpdate`. Use around expensive redirects/API calls (seen with Splashtop-style streams).
- **`Get-UserAgentString`** — browser UA when a vendor blocks default PowerShell clients.
- **`Get-FileNameFromUri`** — Content-Disposition / path segment filename helper.

### Implicit / software-bound variables

When the DV script is attached to Software, Immy may bind:

- **`$SoftwareName`** — display name of the software. Common pattern for multi-edition titles
  (`.NET SDK 6.0 (x86)`, `FileMaker Pro 2025 (x64)`, `MYOB AccountRight 2024`): default it if
  unset, then parse edition/arch/year out of the string to pick the right download.
- **`$DownloadURL`** — pre-supplied URL (parameterized / config-task driven). Used by thin wrappers
  that just wrap `New-DynamicVersion -Uri $DownloadURL -Version 1.0`.
- Rewrite knobs on helpers (`-VersionRewrite`, `-FileNameRewrite`) support `$Var` substitution from
  named capture groups.

Do **not** put tenant secrets, API keys, or per-customer tokens in Global DV scripts. Customer-
specific download URLs belong in Local software parameters / DownloadInstaller auth headers.

### Authoring checklist

1. Search Global software for the title — reuse if DV already works.
2. If writing Local: `scriptCategory=9`, **`scriptExecutionContext=4`**, PowerShell, short `action`.
3. Prefer a one-liner helper call; only hand-roll when helpers cannot express the source.
4. Return the `Versions` envelope (or let the helper return it). Never return a bare string/bool.
5. Keep regex patterns anchored to the real CDN filename; include `FileName` when the URI alone is
   ambiguous.
6. Leave timeout default unless the source is slow; cache redirects with `Invoke-CommandCached`.
7. Wire `useDynamicVersions` + `dynamicVersionsScriptId` (+ DownloadInstaller if needed) on the
   Software record; smoke-test by resolving versions in the UI / script editor (DV editor can run
   without picking a tenant).
8. Default new MSP work to **Local** catalog — only Global if you intend a public contribution.

### Anti-patterns (seen in the wild — avoid for new Local work)

- Reimplementing GitHub/SourceForge/page scrape when a Function helper already exists.
- Using Metascript context `2` for a new DV script (Global DV is consistently `4`).
- Returning a single `PSCustomObject` with `Version`/`URL` at the root **without** the
  `Versions = @(...)` wrapper — helpers and most Global scripts use the wrapper; stick to it.
- Embedding customer API keys in the script body (use parameters / Local DownloadInstaller).
- Multi-thousand-line decryption/CLM experiments in production DV scripts — keep discovery thin;
  push complexity into a Function helper if it must be shared.

## SoftwareVersionAction — install/uninstall real examples

Pulled from the live global catalog. `$InstallerFile` (downloaded by the software's
DownloadInstaller script) and `$InstallerLogFile` are auto-populated variables available in these
scripts. Context is almost always `System` (0) for these — they run directly on the endpoint, no
`Invoke-ImmyCommand` wrapper needed (unlike detection scripts, which often run in Metascript context
and must bridge over).

**EXE installer, Inno Setup style (silent uninstall):**
```powershell
$Uninstallers = Resolve-Path "$($env:ProgramFiles)*\CrystalDiskInfo\unins000.exe"
$Arguments = @"
/VERYSILENT /SUPPRESSMSGBOXES /NORESTART
"@
foreach ($Uninstaller in $Uninstallers) {
    $Process = Start-Process -Wait "$Uninstaller" -ArgumentList $Arguments -Passthru
    Write-Host "ExitCode: $($Process.ExitCode)"
}
```

**MSI install via msiexec, with license key + log capture on failure:**
```powershell
$Arguments = @"
/i "$InstallerFile" /quiet /l*v "$InstallerLogFile" KEYPATH="$LicenseFilePath" CPDF_DISABLE=1 ProductName="Foxit PDF Editor" AUTO_UPDATE=0
"@
$Process = Start-Process -Wait msiexec -ArgumentList $Arguments -PassThru
if ($Process.ExitCode -ne 0) {
    Get-Content $InstallerLogFile | Select-Object -Last 300
}
Write-Host "ExitCode: $($Process.ExitCode)"
```

**Simplest possible install (installer's own defaults handle silence):**
```powershell
$args = "/q /doNotRequireDRMPrompt"
Start-Process -Wait "$InstallerFile" -ArgumentList $args
```

**WMI-based uninstall (for legacy MSI apps with no known product code — slow but reliable fallback):**
```powershell
$MyApp = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "NetDocuments ndMail*" }
$MyApp.Uninstall()
```

## More SoftwareDetection real examples

```powershell
# Wrap Detect-Software's regex mode, coerce to a fixed version string when the software
# doesn't expose a real version anywhere convenient:
$Software = Detect-Software -RegexSoftwareSearchString "^McAfee LiveSafe$"
if ($Software) { return "1.0" }
```
```powershell
# Version from a specific binary's file version info, when the app isn't in the installed-programs table:
$IISCryptoCLI = "$ProgramFiles\Nartac Software\IIS Crypto\IISCryptoCLI.exe"
if ((Test-Path $IISCryptoCLI) -eq $true) {
    return [System.Diagnostics.FileVersionInfo]::GetVersionInfo("$IISCryptoCLI").FileVersion
} else {
    return $null
}
```
Pattern across every detection script sampled: return a version **string** on success, `return $null`
(or nothing) when not found. Never return `$true`/`$false`.

## DownloadInstaller — real examples

`scriptExecutionContext = Metascript` (backend fetches the file, or delegates the actual HTTP call to
the endpoint via `Invoke-ImmyCommand` when the source blocks server-side/backend IPs).

**Generic, hash-verified (the common case — most download-installer scripts are exactly this one-liner):**
```powershell
Download-File -Source $Url -Destination $InstallerFile -ExpectedHash $PackageHash
```

**BITS-avoiding with a spoofed browser User-Agent** (when a vendor's CDN blocks non-browser clients or
`Invoke-WebRequest`'s default UA):
```powershell
$userAgent = Get-UserAgentString "Chrome"
Invoke-ImmyCommand -timeout 600 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    mkdir $Using:InstallerFolder -Force
    Invoke-WebRequest -Uri $Using:URL -OutFile $Using:InstallerFile -UserAgent $Using:userAgent -Headers @{
        "accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        "accept-language" = "en-US,en;q=0.9"
        "cache-control" = "no-cache"
    }
}
```

**Skip re-download when a hash already matches** (avoid wasting bandwidth/time on repeat runs):
```powershell
$ActualHash = Invoke-ImmyCommand { Get-FileHash -Algorithm Sha256 -Path $Using:installerfile | Select-Object -Expand Hash }
if ($ExpectedHash -notlike $ActualHash) {
    Download-File $Url -Headers $AuthHeader -Destination $InstallerFile
} else {
    Write-Progress "Skipping download, hashes match: $ExpectedHash"
}
```

Built-in helpers seen in the wild for this category: `Download-File`, `Get-UserAgentString`.

## FilterScriptDeploymentTarget / MetascriptDeploymentTarget — real examples

Both run in `Metascript`/similar backend context and return which computers/tenants a piece of
software or task should target. The idiomatic pattern is `Get-ImmyComputer -InventoryKeys <key>` piped
through a `Where-Object` filter — cheap, reads cached inventory, no endpoint round-trip:

```powershell
# FilterScriptDeploymentTarget — exclude Windows Home from a deployment
Get-ImmyComputer -InventoryKeys WindowsSystemInfo | Where-Object { $_.Inventory.WindowsSystemInfo.OsName -notlike "*Home*" }

# FilterScriptDeploymentTarget — only computers with a wireless adapter
Get-ImmyComputer -InventoryKeys NetworkAdapters | Where-Object { $_.Inventory.NetworkAdapters.MediaType -match "802\.11" }
```

`MetascriptDeploymentTarget` scripts return a boolean (targets *this* computer/tenant or not) rather
than a filtered collection, and commonly reach out to external systems (Graph API, RMM provider APIs)
to decide:
```powershell
# Tenant-wide Microsoft 365 license check via Graph, paginated
$Headers = Get-ImmyAzureAuthHeader
$ServicePlanNames = Get-ImmySoftwareMicrosoftServicePlans -SoftwareName $SoftwareName
$GraphURI = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName"
while ($GraphURI) {
    $response = Invoke-RestMethod -Uri $GraphURI -Headers $Headers
    foreach ($user in $response.value) {
        $licenseDetails = (Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/users/$($user.id)/licenseDetails" -Headers $Headers).Value
        if ($licenseDetails.servicePlans | Where-Object { $_.ProvisioningStatus -like "Success" -and $ServicePlanNames -contains $_.ServicePlanName }) {
            return $true
        }
    }
    $GraphURI = $response.'@odata.nextLink'
}
return $false
```
```powershell
# Targets computers belonging to tenants mapped in a specific RMM provider (ConnectWise Automate here)
$AutomateClientMappings = Get-RmmInfo -ProviderType CWAutomate -IncludeClients | Select-Object -Expand Clients
$Computer = Get-ImmyComputer | Where-Object { $AutomateClientMappings.TenantId -contains $_.TenantId }
return ($null -ne $Computer)
```
`Get-ImmyAzureAuthHeader` and `Get-RmmInfo` are backend-only helpers not in the `*-Immy*` cmdlet list
(they didn't surface in `/api/v1/scripts/functions` under an Immy-prefixed name) — discover more of
these by reading real scripts rather than assuming a fixed list.

## More MaintenanceTaskSetter (config task) real examples

Confirms the one-script/`switch ($method)` pattern is universal, not just the Hibernation example:

```powershell
# Configure-ChocoSource — test/get/set all in one script
$ExistingSources = choco sources
$TestResult = $true
if ($null -eq ($ExistingSources | Where-Object { $_ -like "*$Source*" })) {
    Write-Warning "No choco sources found with URI $Source"
    $TestResult = $false
}
switch ($method) {
    "test" { return $TestResult }
    "get"  { return "" }
    "set"  {
        if ($Username -and $Password) {
            choco source add -n="$Name" -s="$Source" -u=$UserName -p=$Password
        } else {
            choco source add -n="$Name" -s="$Source"
        }
        return
    }
}
```
Bigger config tasks (e.g. a power-plan manager) define real functions above the `switch`, then have
`"get"` call a reporting function, `"set"` apply changes and `return ""`, and `"test"` compare current
vs. desired state and `return $true`/`$false` — same shape as Hibernation, just with more surface area.
A no-op placeholder task (e.g. one gating manual/human steps) can be as simple as `return $true` for
every method — don't over-engineer a config task that's really just a checklist gate.

### PREFER the built-in `*Should-Be` helpers for registry config tasks (don't hand-roll test/get/set)

For a config task whose whole job is "make these registry values equal X," ImmyBot ships
`$method`-aware helpers that collapse the entire test/get/set dance into a few **declarative** lines —
no `switch ($method)`, no manual `reg load`/hive-loop, no per-profile bookkeeping. You just state the
desired end state; the helper reads the implicit `$method` and behaves correctly (`test` → returns a
bool, `set` → applies, `get` → reports), and ImmyBot aggregates the booleans from *multiple* helper
lines into the task's overall test result (all must pass). This is how real shipped combined scripts
do it (e.g. "Configure Windows Explorer Options Combined Script") — reach for it before writing a
`switch ($method)` block by hand.

**These are Metascript helpers → the script's `scriptExecutionContext` must be `Metascript` (2), NOT
`System`.** They reach onto the endpoint themselves; don't wrap them in `Invoke-ImmyCommand`.

The family (discover more via `GET /api/v1/scripts/functions` filtered to `*Should-Be*`/`*Registry*`):
- **`Get-WindowsRegistryValue -Path <hive:\key> -Name <value> [-IncludeDefaultProfile]`** — the getter
  you pipe into a `*Should-Be`. For an `HKCU:` path it resolves the value across user profiles;
  `-IncludeDefaultProfile` also covers `C:\Users\Default` so **new users inherit** the setting.
- **`RegistryShould-Be -Value <obj> [-Type <String|ExpandString|Binary|DWord|MultiString|Qword>]`** —
  general HKLM (single machine value) or, when the piped path starts with `HKCU:`, it **auto-loops
  every user profile** (no logged-on user required). `-Value $null` *deletes* the value.
- **`HKCUShould-Be -Value <obj> [-Type <...>]`** — the explicit all-profiles HKCU variant; feed it
  `Get-WindowsRegistryValue -IncludeDefaultProfile -Path HKCU:\... -Name ...`.
- **`Get-WindowsControlRegistryValue -SettingName <name>` + `WindowsControlRegistryValueShould-Be
  -Value <obj>`** — a higher-level pair for well-known "Windows Control" settings by friendly name
  (e.g. `WindowsWelcomeExperience`) instead of a raw path.

Real working example (whole script body — keep Location Services disabled *and* suppress the Windows
"Location has been turned off" app popup by turning off "Notify when apps request location" for every
profile + the Default profile):
```powershell
$ConsentStore = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'

Get-WindowsRegistryValue -Path "HKLM:\$ConsentStore" -Name 'Value' | RegistryShould-Be -Value 'Deny' -Type String
Get-WindowsRegistryValue -Path "HKLM:\$ConsentStore\NonPackaged" -Name 'Value' | RegistryShould-Be -Value 'Deny' -Type String

Get-WindowsRegistryValue -IncludeDefaultProfile -Path "HKCU:\$ConsentStore" -Name 'Value' | HKCUShould-Be -Value 'Deny' -Type String
Get-WindowsRegistryValue -IncludeDefaultProfile -Path "HKCU:\$ConsentStore\NonPackaged" -Name 'Value' | HKCUShould-Be -Value 'Deny' -Type String
Get-WindowsRegistryValue -IncludeDefaultProfile -Path "HKCU:\$ConsentStore" -Name 'ShowGlobalPrompts' | HKCUShould-Be -Value 0 -Type DWord
```
Run it with `variables.method = "test"` and each `*Should-Be` streams a per-profile pass/fail line
(including `C:\Users\Default`) plus a final aggregated `True`/`False` — confirming `HKCUShould-Be` fans
out across all profiles + Default automatically. (That `ShowGlobalPrompts=0` line is what actually
suppresses the Windows/Adobe AcroCEF location nag while leaving location itself disabled.)

## Function scripts (category 7) — shared helper library

`Function`-category scripts are loaded automatically into the Metascript runspace and callable by name
from *any* other script — this is ImmyBot's shared-library mechanism. Real examples seen:

- **`Invoke-WindowsDiskCleanup`** — a large, well-structured example of the idiomatic shape for a
  complex Function script: full `param()` block with `[ValidateSet]`/`[switch]` params and rich
  `HelpMessage`s, a "level" convenience parameter that expands into many individual switches via a
  lookup table, `Invoke-ImmyCommand` calls for endpoint discovery and action (each wrapping variables
  through local `$_Foo = $Foo; ... $Using:_Foo` re-binding to dodge closure-capture surprises), and a
  final summary table written with `Write-Host`. Depends on another Function script,
  `Wait-ForProcessActivity`, to monitor long-running endpoint processes without blocking forever.
- **`Invoke-HKCU`** — loops over user profiles, loads each one's `ntuser.dat` registry hive if not
  already mounted (`reg load HKU\<SID> <path>`), mounts `HKCU:`/`HKCR:` PSDrives against it, runs a
  caller-supplied scriptblock, then carefully unmounts and restores the hive's original
  `LastWriteTime`/`LastAccessTime` (Windows uses that to judge "profile last used" — clobbering it
  breaks profile-cleanup tooling). This is the reference pattern for **any** per-user registry
  operation across all profiles on a machine, not just logged-on ones.
- **`Get-WindowsDeviceIdentifier`** — resolves a stable device ID with cascading fallbacks: ImmyBot's
  own registry-stamped ID first, then `Win32_ComputerSystemProduct` UUID via CIM, then via legacy WMI
  if CIM fails. Also flags sandbox/VM-cloned images (checks whether `DNSHostName` looks like a raw
  GUID, a classic golden-image giveaway).

Lesson from all three: **check for an existing Function script before writing endpoint-interaction
boilerplate from scratch.** `GET /api/v1/scripts/global?Filters=scriptCategory==7&PageSize=50` to browse
what's already there.

## Module scripts (category 11) — wrapping a third-party REST API

Modules are plain PowerShell modules (`Export-ModuleMember -Function @(...)`) loaded into the runspace,
used to wrap a vendor's REST API for reuse across many scripts (detection, dynamic versions, deployment
targeting, etc. for that vendor's product). Real example, `HuntressAPI`:

```powershell
function Connect-HuntressAPI {
    param([Parameter(Mandatory)][string]$AccountKey, [Parameter(Mandatory)][string]$APIKey,
          [Parameter(Mandatory)][string]$SecretKey, [Uri]$BaseURL = 'https://api.huntress.io/v1')
    $SecureSecretKey = ConvertTo-SecureString -AsPlainText $SecretKey -Force
    $Script:Credential = New-Object System.Management.Automation.PSCredential -ArgumentList $APIKey, $SecureSecretKey
    $Script:BaseURL = $BaseURL
}

function Invoke-HuntressRestMethod {
    param([Parameter(Mandatory)][string]$BaseURL, [Parameter(Mandatory)][PSCredential]$Credential,
          [Parameter(Mandatory)][string]$Endpoint, [string]$Method = "GET",
          [hashtable]$QueryParameters = @{}, [object]$Body, [switch]$AllPages)
    # ... builds query string, calls Invoke-RestMethod -Authentication Basic -Credential $Credential,
    # retries with exponential backoff on HTTP 429, follows $response.pagination.next_page_url when -AllPages
}

Export-ModuleMember -Function @('Connect-HuntressAPI', 'Invoke-HuntressRestMethod', 'Get-HuntressAccount', ...)
```
Reusable shape for wrapping any REST API as an ImmyBot module: one `Connect-*` function that stashes
credentials/base URL in `$Script:` scope (or `$IntegrationContext` when the module backs a real
Integration provider type), one generic `Invoke-*RestMethod` that centralizes auth/pagination/retry,
and thin `Get-*`/`Set-*` wrappers on top. Basic-Auth vendors: build a `PSCredential` and pass
`-Authentication Basic -Credential $cred` to `Invoke-RestMethod` rather than hand-rolling an
`Authorization` header.

## Preflight scripts (category 12) — gate a maintenance session

Preflight scripts run before a maintenance session and can block it from proceeding. Real example,
"Is Machine Fully Booted" (guards against running maintenance mid-OOBE/mid-upgrade):

```powershell
if (!$Computer) { return $true }   # not run against a real computer (e.g. a cloud script) — don't gate

while (!$BootComplete) {
    $TestResults = Invoke-ImmyCommand -ErrorAction Stop {
        $Processes = Get-Process logonui, explorer -ErrorAction SilentlyContinue
        return @{ LogonUI = !!($Processes | Where-Object Name -like "logonui"); Explorer = !!($Processes | Where-Object Name -like "explorer") }
    }
    if ($TestResults.LogonUI -or $TestResults.Explorer) { return $true }
    Start-Sleep 3
}
```
Notice it just `return`s a bool directly and polls with a plain `while` + `Start-Sleep` loop inside the
script — no special "wait" API needed, `Invoke-ImmyCommand` is just called repeatedly. `$Computer` and
similar implicit variables are bound automatically based on the script's category/context; don't
declare them in a `param()` block.

## Windows-side PowerShell gotchas seen in real deployment scripts

- PS5.1 `Expand-Archive` requires a `.zip` extension — copy `.whl` (or any other archive-format-but-
  wrong-extension) file to a temp `.zip` path before expanding.
- `Set-Content -Encoding UTF8` on PS5.1 adds a BOM that breaks strict parsers (Python dotenv, a
  `._pth` file, etc.). Write with
  `[System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::ASCII)` when the consumer
  is BOM-sensitive.
- If two versions of an interpreter/runtime are already registered on a box, an installer picking a
  `TargetDir` different from the default system path can leave the two halves of an install (e.g.
  `python.exe` vs `Lib\`) unable to find each other — prefer embeddable/self-contained packages when
  you need a clean, isolated install.
- **ImmyBot's default script execution context is Windows PowerShell 5.1, not PowerShell 7+** (this
  is also why `pwsh` isn't guaranteed to exist on a target endpoint — see the `pwsh`-not-found gotcha
  elsewhere in this project). Any script pushed through ImmyBot (as a catalog script, ad-hoc run, or
  a script called by one that ends up running locally) that uses PS7-only syntax will fail to
  **parse** — not just at runtime — with a generic-looking `Unexpected token` error that doesn't
  mention the real cause. Confirmed offenders: the null-coalescing operator `??`, the null-coalescing
  assignment `??=`, the ternary operator `? :`, and the null-conditional member access `?.`. Write
  `if/elseif/else` instead of `??`/ternary, and `if ($x) { $x.Prop }` instead of `$x?.Prop`. Test any
  script you're unsure about by running it as an ad-hoc script against a real computer (see
  `api-reference.md`'s "Testing a script or task against a real computer" section) rather than only
  syntax-checking it locally in a PS7 terminal, since PS7 will happily parse and run PS5.1-illegal
  syntax without complaint.
  PS7 syntax/cmdlets *are* reachable when you actually need them: from the ImmyBot Discord (Noah
  Tatum, 2024-03-13, on `New-SshLocalPortForward` failing under 5.1 but working under 7) — "You could
  always call `pwsh` within `Invoke-ImmyCommand`... this at least works." i.e. wrap the PS7-dependent
  logic in its own scriptblock and invoke it via `pwsh -Command { ... }` (or a saved `.ps1`) from
  inside the PS5.1 script, rather than trying to write PS7 syntax directly in the outer script body.
  This still depends on `pwsh` actually being installed on that endpoint — don't assume it's there
  (see the `pwsh`-not-found gotcha) — verify or install it first if you go this route.
- A background/service process launched with `python.exe` (not `pythonw.exe`) spawns a visible
  console window — which, on a machine also used for GUI automation (computer-use style
  clicking/typing), can silently steal foreground/input focus from whatever app you're trying to
  automate. Symptom: your target app renders correctly in screenshots (still visually on top) but
  clicks/keystrokes never seem to register, because they're actually landing on your own background
  console. Diagnose by checking `GetForegroundWindow()` before/after a simulated click, not just by
  trusting that a click "should" go to whatever's visually on top. Fix: use `pythonw.exe` for any
  long-running background automation process, and don't assume a single `SetForegroundWindow` call
  early in the process lifetime is enough to keep a target app focused — Windows' foreground-lock
  restriction can silently ignore `SetForegroundWindow` from a background/automated process; use
  `AttachThreadInput` around it for a reliable steal, and retry until the target window actually
  exists rather than assuming a fixed delay after launch is long enough.
