# Changelog

All notable changes to this skill are documented here. Everything was verified live against a real
ImmyBot tenant's Swagger spec and API, not guessed from general docs.

## [1.4.0] - 2026-07-16

### Changed
- **Corrected the Global vs Local catalog semantics** (previously described backwards). `Global` is
  ImmyBot's shared/community catalog that syncs across *every ImmyBot instance* — writing there
  effectively **publishes your script to the public ImmyBot codebase**. `Local` is *your own
  instance's* catalog, private to your company. **Default to Local** for normal MSP work; only use
  Global when the explicit intent is a public contribution. "Reusable across *your own* tenants" is a
  separate axis — tenant visibility within Local (`visibleToAllTenants`), not Local vs Global.

### Added
- **Documented the built-in registry `*Should-Be` helper family** and the declarative combined-script
  idiom for registry config tasks — the preferred alternative to a hand-rolled `switch ($method)`:
  - `Get-WindowsRegistryValue -Path ... -Name ... [-IncludeDefaultProfile]` as the getter you pipe in.
  - `RegistryShould-Be` (HKLM, or auto-loops all user profiles on an `HKCU:` path) and `HKCUShould-Be`
    (all profiles + the Default profile) — both `$method`-aware (test → bool, set → apply).
  - `Get-WindowsControlRegistryValue` / `WindowsControlRegistryValueShould-Be` for named "Windows
    Control" settings.
  - These are **Metascript-context** helpers; ImmyBot aggregates multiple `*Should-Be` lines into the
    task's overall test result. No manual `reg load`/hive looping needed.

## [1.3.0]

### Added
- "Runs Against" selector gotcha: default deployments to Computers, and note that config/maintenance
  tasks can't deploy standalone.

## [1.2.0]

### Added
- DevExtreme `/dx` scale patterns and an action-first weekly reporting path: `requireTotalCount=true`
  (not the date filter) is the timeout culprit on wide `maintenance-actions/dx` windows; group/filter
  on integer enum fields (`actionType`/`result`), not the `*Name` strings (which 500); `actionType`/
  `result` enum maps; day-windowed, `NoAction`-excluded weekly reporting (~7 calls/week vs 14k).

## [1.1.0]

### Added
- PS7-only syntax (`??`, ternary, `?.`) fails to *parse* under ImmyBot's default Windows PowerShell
  5.1 context — with the `pwsh`-inside-`Invoke-ImmyCommand` workaround.
- Reading/updating a deployment's parameter overrides via the target-assignments API.
- Console-window focus-stealing bug for background GUI-automation processes (`pythonw.exe` fix).
- `POST /api/v1/scripts/run` hard ~120s gateway timeout, and the "submit-and-poll" restructure.
- "Onboarding" naming collision (ImmyBot's device-lifecycle term vs. generic onboarding).
- Install-time parameter baking: params written to disk at install don't update live until reinstall.

## [1.0.0]

### Added
- Initial ImmyBot skill for Claude Code: Azure AD OAuth2 auth, core concepts, gotchas, the REST API
  reference, and the PowerShell scripting guide (script categories/contexts, `Invoke-ImmyCommand`,
  built-in `*-Immy*` cmdlets, and real worked examples).
