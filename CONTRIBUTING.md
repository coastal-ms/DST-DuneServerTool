# Contributing

Thanks for your interest in improving the Simple Dune Server Management Tool!

## Change control workflow

1. **Open an issue first** for anything non-trivial — bug, feature, or
   behavior change. This lets us discuss the approach before code is written.
2. **Branch from `main`** using a short prefix:
   - `feat/<name>` — new feature
   - `fix/<name>` — bug fix
   - `docs/<name>` — docs only
   - `chore/<name>` — tooling, CI, refactor
3. **Make focused commits.** One logical change per commit. Reference the
   issue in the commit body (e.g. `Refs #12`).
4. **Update `CHANGELOG.md`** under the `[Unreleased]` section.
5. **Open a PR** against `main`. The PR template will prompt for testing
   notes and a summary.
6. **CI must be green** — see [PSScriptAnalyzer lint](.github/workflows/lint.yml).
7. A maintainer reviews, may request changes, then merges (squash by default).

## Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **MAJOR** — breaking changes to the menu, config file, or CLI args.
- **MINOR** — new menu options, new config keys, backward-compatible features.
- **PATCH** — bug fixes, docs, internal refactors.

Bump `$script:ToolVersion` in `dune-server.ps1` and move the
`[Unreleased]` block in `CHANGELOG.md` into a new version section when cutting
a release. Tag with `v<version>` and push the tag.

## Local development

```powershell
# Parse-validate the script (fastest feedback loop):
$tokens=$null; $errs=$null
[System.Management.Automation.Language.Parser]::ParseFile(
    "$PWD\dune-server.ps1", [ref]$tokens, [ref]$errs) | Out-Null
$errs

# Lint with PSScriptAnalyzer:
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path .\dune-server.ps1
```

## Coding standards

- PowerShell 7+ syntax.
- Functions use approved verbs (`Get-`, `Set-`, `Test-`, `Confirm-`, ...).
- Prefer `Write-Host` with explicit `-ForegroundColor` for user-facing output;
  it's a CLI tool, not a pipeline-friendly module.
- No secrets in code or in committed config — read from
  `dune-server.config` (which is `.gitignore`d) or prompt.
- Keep platform assumptions explicit (`#Requires -RunAsAdministrator`,
  Hyper-V, Windows 10/11).

## Security

If you find a security issue (e.g. credential disclosure, command injection),
please **do not** open a public issue. Email the maintainer or open a
GitHub Security Advisory instead.
