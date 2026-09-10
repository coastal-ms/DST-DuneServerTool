# Hyper-V VM lifecycle

DST can reconcile a Self-Hosted `dune-awakening` VM so Windows host shutdown
requests a graceful guest shutdown and Alpine preserves the Funcom battlegroup's
prior running state across the boot.

The feature is opt-in under **Settings > Hyper-V VM lifecycle**. Reading status
does not change the host or guest.

## Safety boundary

Reconcile changes only:

- the VM's Hyper-V **Operating System Shutdown** integration enabled state,
  selected by its stable integration-service GUID; and
- the VM's **Automatic Stop Action**, set to `ShutDown`.

DST does not change Automatic Start Action, dynamic memory, checkpoints, VSS,
file-copy, KVP host settings, VM networking, or other VM configuration.
Alpine's kernel `hv_utils` shutdown support and the shutdown VMBus channel must
both be present before any lifecycle change is allowed. DST does not install or
enable `hv_fcopy_daemon` or `hv_vss_daemon`.

The guest lifecycle service:

- depends on OpenRC `k3s`, so its stop hook runs before k3s stops;
- uses `/home/dune/.dune/bin/battlegroup stop` and waits for the established
  Funcom battlegroup pod set to drain;
- records shutdown failure durably but releases OpenRC after 300 seconds;
- restarts only when the battlegroup was running before shutdown;
- waits for the k3s API, database pods, operators, webhook endpoints, and the
  established battlegroup readiness fields, with a 900-second bound. The
  top-level Funcom phase may be `Running` (current) or `Healthy` (legacy), but
  database must be `Ready` or `Healthy`, gateway must be `Healthy` or `Running`,
  director must be `Healthy` or `Ready`, and every reported game server must be
  `Running` with `ready=true`; and
- records startup success, failure, or skip state for the Settings status view.

Reconcile snapshots original host and guest state before mutation. Removal
requires that snapshot to match the current host and VM identity; DST refuses to
guess if the snapshot is missing, unreadable, or belongs to another VM.

## Disposable-VM acceptance plan

Run this plan only on an isolated Hyper-V host and a disposable clone of the
supported Alpine/Funcom VM. Do not use a production server.

1. Record the disposable VM ID, Automatic Start Action, Automatic Stop Action,
   all integration-service enabled states, memory settings, network adapters,
   checkpoints, and current battlegroup readiness.
2. With lifecycle integration absent, open Settings and refresh status. Confirm
   this read-only action changes none of the recorded host or guest values.
3. Disable Operating System Shutdown and set Automatic Stop Action to `Save`.
   Reconcile from Settings. Confirm only Operating System Shutdown becomes
   enabled and Automatic Stop Action becomes `ShutDown`; all unrelated values
   must match the baseline exactly.
4. Confirm the guest reports `hv_utils=true`, `shutdown_channel=true`,
   `installed=true`, `runlevel=true`, and `service_started=true`. Confirm the
   generated OpenRC service declares `need k3s`.
5. With a healthy battlegroup running, request a normal Windows host shutdown.
   Confirm the guest records `DESIRED=running`, invokes the product
   `battlegroup stop` path, drains the established Funcom pods, and powers off
   before the 300-second bound.
6. Boot the host and VM. Confirm k3s becomes ready before battlegroup recovery,
   the database and operators become ready before webhook and battlegroup
   startup, and Settings reports a successful durable startup result.
7. Stop the battlegroup intentionally, then repeat host shutdown and boot.
   Confirm the guest records `DESIRED=stopped` and does not restart it.
8. In a second disposable run, force pod drain to exceed 300 seconds. Confirm
   the durable shutdown result is failed, OpenRC continues host shutdown, and
   Windows is never blocked indefinitely.
9. Force each reconciliation failure point in turn: guest staging, OpenRC
   runlevel update, guest readback, Hyper-V integration enable, Automatic Stop
   Action update, and host readback. Confirm the pre-test host and guest state
   is restored or that the error explicitly reports any compensation failure.
10. Force each removal failure point in turn. Confirm DST either restores the
    original host and guest state or compensates back to the fully configured
    lifecycle state; no mixed host/guest state may be reported as success.
11. Change the disposable VM ID or target host after reconciliation. Confirm
    removal and further reconciliation fail closed without changing either
    system.
12. Remove lifecycle integration normally. Confirm the original Operating
    System Shutdown enabled state, Automatic Stop Action, guest files, OpenRC
    runlevel membership, service state, and any pre-existing same-path files
    are restored exactly.
13. Compare the final full Hyper-V inventory to step 1. Aside from values
    deliberately restored to their baseline, there must be no difference.

## References

- [Microsoft Hyper-V integration services](https://learn.microsoft.com/windows-server/virtualization/hyper-v/integration-services)
- [Linux `hv_utils` implementation](https://github.com/torvalds/linux/blob/master/drivers/hv/hv_util.c)
- [Alpine `hvtools` package contents](https://pkgs.alpinelinux.org/contents?branch=edge&name=hvtools&arch=x86_64&repo=community)
- [OpenRC service script guide](https://github.com/OpenRC/openrc/blob/master/service-script-guide.md)
