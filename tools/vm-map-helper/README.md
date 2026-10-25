# VM map development utilities

This directory contains development utilities and shared Python modules for
VM-hosted Live Maps. The installed helper is in `app/tools/VmMapHelper`.

- Observations and database queries are read-only. The API accepts no arbitrary
  SQL or shell commands.
- `access.py` and `gateway.py` implement the isolated development gateway and its
  delegated map access. The installed helper uses DST's authenticated routes.
- `prepare.py` and `deploy.py` create a separate, resource-bounded development
  pod. Generated bundles contain private server data and access material and
  belong outside the repository.
- `Stop-Prototype.ps1` removes the isolated development pod without stopping game
  servers or removing its private bundle.

Map artwork uses the existing locally packaged assets.
