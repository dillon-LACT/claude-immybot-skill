# claude-immybot-skill

A [Claude Code](https://claude.com/claude-code) skill for working with [ImmyBot](https://immy.bot), an RMM/MSP automation platform. It covers:

- Calling the ImmyBot REST API (Azure AD OAuth2 client-credentials auth, global/local script and software catalogs, maintenance sessions)
- Writing ImmyBot PowerShell content (detection scripts, dynamic-version scripts, install/uninstall scripts, config/maintenance tasks, `Invoke-ImmyCommand` and other built-in Immy cmdlets)

Everything in this skill was verified live against a real ImmyBot tenant's Swagger spec and API, not guessed from general docs.

## Install

Clone this repo directly into your Claude Code skills directory:

```powershell
git clone https://github.com/<your-username>/claude-immybot-skill.git "$env:USERPROFILE\.claude\skills\immybot"
```

Or, for a single project only, clone into `.claude/skills/immybot` at the project root.

Claude Code will pick it up automatically — trigger it by mentioning ImmyBot, `immy.bot`, detection scripts, config tasks, or `Invoke-ImmyCommand`.

## Usage

For API calls, set these environment variables (from an Azure AD app registration under **Entra ID > App registrations** on your ImmyBot tenant):

```powershell
$env:IMMYBOT_AAD_TENANT_ID = "..."
$env:IMMYBOT_CLIENT_ID     = "..."
$env:IMMYBOT_CLIENT_SECRET = "..."
$env:IMMYBOT_BASE_URL      = "https://yourcompany.immy.bot"
```

Then dot-source `scripts/Connect-ImmyBot.template.ps1` (copy it into your own project first — don't commit a filled-in copy with a real client secret) to get an authenticated `$headers` ready for any ImmyBot API call.

## Structure

- `SKILL.md` — entry point Claude reads first: auth, core concepts, and known gotchas
- `references/api-reference.md` — REST API details: pagination/filter params, script-push pattern, ad-hoc execution, maintenance-session endpoints
- `references/scripting-guide.md` — PowerShell content guide: script categories/execution contexts, the full `Invoke-ImmyCommand` signature, all built-in `*-Immy*` cmdlets, and real worked examples
- `scripts/Connect-ImmyBot.template.ps1` — copy-paste auth template, reads from env vars

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for notable changes across versions.

## Contributing

Corrections and additions are welcome, especially anything reproducible against a live tenant's Swagger spec. Open a PR or issue.

## License

MIT — see [LICENSE](LICENSE).
