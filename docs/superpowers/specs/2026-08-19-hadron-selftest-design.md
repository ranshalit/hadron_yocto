# Hadron NGX012 Interface Self-Test — Design

**Date:** 2026-08-19
**Status:** Approved
**Artifact:** `scripts/hadron-selftest.py`

## Purpose

A host-side script that SSHes into the Hadron NGX012 device and verifies that all
hardware interfaces are functional: ethernet, USB host ports, the UVC camera, the UART
camera and PixHawk serial links, the onboard serial console, and the BMI160 IMU.

It prints a colored PASS / WARN / FAIL table and supports `--json` for machine-readable
output. Intended for bring-up and post-flash smoke testing from the developer host.

## Scope

- **In:** ethernet, USB host ports, UVC camera, `/dev/ttyCAM`, `/dev/ttyPixHawk`,
  onboard serial (`ttyTHS1`), BMI160 IMU.
- **Out:** GPU/CUDA, PCIe, audio, throughput/benchmark testing, on-device installation
  (the script is host-side only and assumes the device already runs the Yocto image).

## Test Depth

Mixed: presence checks for interfaces that are hard to exercise, active I/O where it is
cheap and reliable.

## Missing-Peripheral Policy

Core buses must pass; optional peripherals that are simply not attached produce a yellow
WARN, not a failure.

- **FAIL-worthy (core):** ethernet, USB xHCI controllers, onboard serial console.
- **WARN-worthy (optional peripheral absent):** UVC camera, ttyCAM, ttyPixHawk, IMU —
  but if the peripheral IS present and its I/O test fails, that is a FAIL.

## Configuration

Reads `.env` using the same lookup order as the ethernet-console skill:

1. Already-exported shell / process environment variables.
2. `.env` in the current working directory.

Keys: `HADRON_IP`, `HADRON_SSH_USER`, `HADRON_SSH_PASS`, `HADRON_SSH_CONNECT_TIMEOUT`
(default 10s).

CLI flags override env: `--ip`, `--user`, `--password`, `--timeout`, `--json`,
`--only <check>[,<check>...]`.

## Architecture

Single Python 3 script, standard library only. No paramiko: connectivity is via
`sshpass ssh` subprocesses, matching the existing `eth_transfer.py` / ethernet-console
conventions (`sshpass` is already a documented host dependency).

Components:

- **Config loader** — resolves connection settings from env then `.env`, applies CLI
  overrides, validates that IP/user/password are present.
- **`remote(cmd, timeout)` helper** — runs a command on the device over
  `sshpass ssh -o StrictHostKeyChecking=no -o ConnectTimeout=…`, returns
  `(rc, stdout, stderr)`. Every call is time-bounded so a hung port cannot stall the run.
- **Check functions** — one per interface, each returns `CheckResult(name, status,
  detail)` where `status` ∈ `PASS | WARN | FAIL`. Each catches its own exceptions and
  maps them to a FAIL row carrying the error text.
- **Reporter** — renders the collected results either as a colored aligned table
  (default) or as JSON (`--json`).
- **Runner** — orchestrates: reachability preflight, run selected checks, report, set
  exit code.

## Data Flow

```
.env / env / CLI ─▶ Config
Config ─▶ preflight reachability (host ping + one SSH echo)
          │ unreachable ─▶ abort with clear message, exit 2
          ▼
       for each selected check:
          check() ─▶ remote(cmd) ─▶ CheckResult(status, detail)
          ▼
       Reporter (table | json)
          ▼
       exit 0 (no FAIL) or 1 (any FAIL)
```

## Checks

| Check | Method | PASS | WARN | FAIL |
|---|---|---|---|---|
| `ethernet` | Host `ping -c1 -W2 <ip>`; remote `ip -br addr show eth0` | ping ok, eth0 UP, addr `192.168.132.100` | — | unreachable, link down, or wrong IP |
| `usb_ports` | Remote inspect xHCI root hubs under `/sys/bus/usb/devices`; `lsusb` | both xHCI controllers present | a root-hub port has no device attached | xHCI controller missing |
| `uvc_cam` | Remote: `/dev/video0` exists, then grab 1 frame (`v4l2-ctl --stream-mmap --stream-count=1`, fallback `python3-v4l2py`) | frame captured | no `/dev/video*` node | node present but capture errors |
| `tty_cam` | Remote: `/dev/ttyCAM` symlink present | symlink present | absent | — |
| `tty_pixhawk` | Remote: `/dev/ttyPixHawk` present, then read one MAVLink heartbeat via `pymavlink` (short timeout) | heartbeat received | device absent | present but no heartbeat within timeout |
| `onboard_serial` | Remote: `/dev/ttyTHS1` present | present | — | absent |
| `imu` | Remote: BMI160 iio device under `/sys/bus/iio/devices`, read one raw sample | sample read | device absent | present but read errors |

## Error Handling

- **SSH unreachable at preflight** → abort entire run, print the actionable reason
  (wrong IP / device off / auth), exit code 2. Distinguish connectivity failures
  (`Connection refused`, `timed out`, `No route to host`, `Network is unreachable`) from
  auth failures (`Permission denied`, `Host key verification failed`), which are surfaced,
  not retried.
- **Per-check exception / non-zero rc** → that row becomes FAIL (for core) or the check's
  documented WARN (for optional-absent), carrying the trimmed error text in `detail`.
- **Timeouts** → each `remote()` call is bounded; a timeout maps to FAIL/WARN per the
  check's policy rather than hanging the run.

## Exit Codes

- `0` — all selected checks PASS or WARN.
- `1` — at least one check FAIL.
- `2` — device unreachable / could not start (nothing tested).

## Output

**Table (default):** aligned rows `CHECK  STATUS  DETAIL`, colored green/yellow/red, with
a trailing summary line (`6 PASS, 1 WARN, 0 FAIL`).

**JSON (`--json`):** `{"device": "<ip>", "results": [{"name", "status", "detail"}, …],
"summary": {"pass", "warn", "fail"}, "exit_code": N}`. Colors suppressed.

## Testing

- Run against a live device with peripherals attached → expect all PASS.
- Run with a peripheral unplugged → expect that row WARN, exit 0.
- Run against a wrong/unreachable IP → expect abort, exit 2.
- `--json` output validated as parseable JSON.
- `--only ethernet,imu` runs just those two checks.

## Non-Goals / YAGNI

No continuous monitoring, no HTML report, no throughput benchmarks, no on-device install,
no retry loops beyond the single per-check timeout.
