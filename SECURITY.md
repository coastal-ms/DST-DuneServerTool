# Security Policy

## Supported versions

DST ships as a rolling release. Only the **latest published release** on the
[Releases page](https://github.com/coastal-ms/DST-DuneServerTool/releases/latest)
receives security fixes. The in-app auto-updater keeps installs current; please
update before reporting an issue to confirm it still reproduces.

| Version            | Supported |
| ------------------ | --------- |
| Latest release     | ✅        |
| Older releases     | ❌        |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems** (e.g.
credential disclosure, command injection, path traversal, SSRF, or anything
that could compromise a user's server, VM, or credentials).

Report it privately through either channel:

1. **GitHub Security Advisories (preferred).** Use
   **[Report a vulnerability](https://github.com/coastal-ms/DST-DuneServerTool/security/advisories/new)**
   on the repository's Security tab. This opens a private advisory visible only
   to the maintainer.
2. **Discord.** DM **`@allcoast`** in the
   [DST community Discord](https://discord.gg/tj2x7cywSC) and ask to open a
   private security thread.

Please include:

- The affected version (portal footer, e.g. `v12.15.0 · coastal-ms`).
- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- **Sanitize first** — remove real IPs, hostnames, usernames, and any SSH key
  contents from anything you attach.

### What to expect

- **Acknowledgement:** within a few days.
- **Assessment & fix:** confirmed issues are prioritized for the next release;
  timing depends on severity and complexity.
- **Disclosure:** we'll coordinate a disclosure timeline with you and credit
  you in the release notes unless you'd rather stay anonymous.

## Release integrity

- Official binaries are distributed **only** as the `DuneServerSetup.exe` asset
  on this repository's [GitHub Releases](https://github.com/coastal-ms/DST-DuneServerTool/releases).
  Do not trust DST installers obtained from anywhere else.
- Releases are built from this public repository. Authenticode **code signing
  via [SignPath Foundation](https://signpath.org/)** (free OSS signing) is being
  rolled out so release binaries carry a verifiable publisher signature — see
  [`.github/workflows/release-signed.yml`](.github/workflows/release-signed.yml).
- DST never transmits your SSH keys, server credentials, or public IP off your
  machine. Configuration is stored locally under `%APPDATA%\DuneServer\`.

## Scope

This policy covers the DST application in this repository (the PowerShell
backend, the web UI, the desktop shell, and the installer). It does **not**
cover the upstream **Dune: Awakening** dedicated server software itself, which
is published by Funcom — DST is an unaffiliated third-party admin tool.
