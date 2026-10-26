# VM-hosted Live Map helper

Live Maps is optional. Enabling it authorizes DST to install the helper
automatically. Allow 500 MB of free disk space for initial setup, including
Python, maps, icons and working data. This uses the VM's existing available
resources; it does not allocate extra VM RAM. The helper's container has a
250 MB RAM limit, rather than constant usage. Retained helper revisions can
use additional disk space over time.

A single private collector performs observations, processing and shared caching
on the VM. Existing DST authenticated map routes display the same embedded map
and forward requests through one persistent SSH connection. Existing viewer
permissions, logout and session revocation apply at DST on every request.
There is no public helper listener, separate login, account-verifier mirror,
additional website or Tailscale requirement. The desktop forwards responses;
it does not run a duplicate collector. The gateway from the rejected candidate
is removed during migration, and its VM-only public route is retired.

Collection yields while idle and has bounded CPU/memory. Health probes never
create viewer leases. Updates preserve map preferences and warm caches; failed
rollouts restore the prior deployment. Removing the helper leaves game servers
and existing DST remote access intact.
