# Ouro Broker

`ouro-broker` owns PTYs outside the Ourocode UI process. It is a single
non-blocking `poll(2)` loop over the Unix listener, clients, and PTY masters;
there is no client/session thread. macOS and Linux use the same implementation.

## Run

```sh
cargo run --manifest-path crates/ouro-broker/Cargo.toml -- "$TMPDIR/ourocode/broker-v3.sock"
```

The socket is created with mode `0600`. A pre-existing non-socket path is never
removed. Filesystem permissions are only the first boundary: the broker rejects
accepted peers whose kernel-reported UID differs from its effective UID, and the
desktop client performs the reciprocal check. The desktop app should launch one
broker per login user, reconnect to the socket after its own restart, and treat
the broker's initial `hello` as the authoritative incarnation. Each incarnation
is a nonzero 64-bit value from the operating system CSPRNG; failure to obtain
randomness aborts binding before the socket path is touched.

## Wire protocol

The transport is newline-delimited JSON; binary `data` fields are standard
base64 strings so a bounded 512 KiB snapshot fits the bounded client queue. Every request contains
`{"version":3,"id":N,"op":"..."}`. Every server message contains
`version` and `broker_generation`; the broker sends `type: "hello"` immediately
after accept. That hello also contains the broker `build` and a bounded
`capabilities` list. The v3 desktop client enables attach only when the broker
advertises exactly the supported canonical recovery contract
`terminal.recovery.ansi_replay.viewport.v1` plus
`terminal.resume.delta.v1`, `terminal.create.idempotency.v1`, and
`terminal.terminate.reaped_ack.v1`; missing lifecycle contracts or unknown
recovery contracts fail closed.

Protocol v3 uses `broker-v3.sock`. It never probes, unlinks, or terminates a
`broker-v2.sock`, because a v2 broker may still own live sessions. Commands are:

- `create`: stable `create_nonce`, `program`, `args`, optional `current_directory` and environment overrides, `columns`, `rows`
- `list`
- `attach`: `terminal_id`, `broker_generation`, optional `after_cursor`
- `input`: terminal/generation plus the `input_epoch` and `lease_id` returned by attach
- `resize`: the same authority tuple plus `columns` and `rows`
- `terminate`: terminal and broker generation

Attach without a cursor returns a bounded snapshot. Attach with the current
generation and a retained cursor returns ordered deltas after that cursor; an
expired delta window returns a snapshot. Each output chunk increments a
terminal-local monotonic cursor. A new attach rotates the exclusive,
connection-bound input lease, so stale or disconnected windows fail closed. A broker restart changes `broker_generation`, so
mutations from the previous incarnation fail closed.

Protocol v4 additionally advertises `terminal.surface.identify.v1`. A creator
may call `identify_surface` with the exact `terminal_id`, broker generation,
Create nonce, and five-part session binding. The broker returns an opaque,
idempotent `producer_receipt` only after reaping stale children and proving via
`getsid(2)`, `tcgetsid(3)`, and `tcgetpgrp(3)` that the successful exec remains
the PTY session leader and that the foreground process group belongs to the
same session. The call is restricted to the creating connection incarnation.
The receipt is never included in `list`, terminal summaries, or tombstones.

`create_nonce` makes a repeated create with identical parameters return the
same terminal and rejects nonce reuse with different parameters. The nonce is
projected by `list`, so a client can reconcile a request whose reply timed out.
`terminate` acknowledges only after the child has exited and `waitpid` has
reaped it; repeated termination of a tombstone is idempotently acknowledged.

All input, client output, delta, snapshot, client, and terminal collections are
bounded. A slow subscribed client is disconnected when its output queue fills;
it must reconnect and resume/snapshot. A terminal remains alive when a client or
the entire UI process disconnects. `terminate` signals the terminal foreground
process group, escalates from HUP to TERM/KILL, and non-blockingly reaps the shell before acknowledging the request.

## Fanout smoke

Run `crates/ouro-broker/scripts/fanout-32.sh` to build the current release source,
start 32 UI-less PTYs, push 640 KiB through every terminal (past each 512 KiB
snapshot/delta bound), verify all 32 survive client disconnect, and print raw
thread/RSS/OS footprint data. The checked-in
`benchmarks/fanout-32-canonical-v1-idle-macos-arm64-20260809.txt` is one
machine/run, not a cross-machine comparison or a general memory guarantee. Its
measured broker had one thread, a 23 MiB physical footprint, and 0.0% sampled
CPU after a ten-second idle settle while all 32 shells remained alive.
