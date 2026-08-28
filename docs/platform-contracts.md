# Platform contracts

The first next-generation platform slice is additive. It does not add a player
role, account/session persistence, API keys, Discord identity, cache storage, or
new game-domain entity shapes. Existing local-host, Owner, Admin, token, legacy
remote, and local-only behavior remains authoritative.

## Backend-owned contracts

- `app/data/platform-capabilities.json` is the versioned capability registry.
  Unavailable entries reserve reviewed future IDs but are never returned as
  currently available capabilities.
- `app/data/platform-route-policies.json` classifies every registered HTTP and
  WebSocket route by an exact per-source route-set fingerprint. Adding, removing,
  or renaming a route invalidates that source group until its policy is reviewed.
  Reviewed source write lifecycles plus exact lifecycle and capability overrides
  avoid inferring safety or authority from route names. Classification fails
  closed when a route lifecycle exceeds its capability or the capability omits a
  currently authorized principal. An invalid or missing classification is denied
  to future player, API-key, and Discord principals.
- `app/data/platform-candidate-matrix.json` records every reviewed plan candidate,
  its decision, owning epic, consolidation target, lifecycle phase, capability,
  and a positive acceptance-test target.
- `GET /api/v1/capabilities` returns the registry filtered for the server-created
  request principal. `GET /api/v1/platform/status` proves the common envelope and
  contract versions without changing legacy routes.

`requestPrincipal`, `requestId`, `routeCapabilityId`, and `routeClassification`
are injected into route parameters by the server. Principals are derived only
from admitted transport and server-side session/account state. Request body,
query, and arbitrary client identity fields are not consulted.

## Response and cursor rules

Version 1 envelopes carry a request ID, generation time, source, freshness,
capability IDs, data, and page metadata. Mixed map snapshots use a separate
envelope for each layer, including that layer's source, freshness, count,
cursor/truncation state, and error. The aggregate may be `mixed` or `partial`
without hiding a successful layer behind another layer's failure.

Opaque cursor helpers sign a binding over principal identity, map, normalized
layer set, bounding box, query hash, and generation. A cursor is rejected if any
binding changes or if its signature is modified.
