# app/lib/

Backend helper modules for v6.0 "Server Manager" release.

| File | Purpose |
|------|---------|
| `Db-Postgres.ps1` | `kubectl exec` wrapper for `psql` queries against the battlegroup database. Read-only by default; writes require `-Write` switch. |
| `Ini-Edit.ps1`    | Safe INI read/write over SSH (atomic via temp file + `mv`). Used by Game Config page. |
| `Hyperv.ps1`      | Hyper-V cmdlet wrappers (status, import, configure, resize). Used by Dashboard + Setup Wizard. |
| `K8s.ps1`         | Battlegroup CRD patch helpers (image versions, sietch add/remove). |
| `StateModel.ps1`  | Script-scope observable state (BG state, VM state, current page, current character). |

SQL strings, INI mutations, and K8s patch payloads are translated from the
MIT-licensed `dune-awakening-server-manager` reference's `server.js` and
reimplemented in PowerShell to match this tool's stack.
