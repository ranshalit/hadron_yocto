# Boot-timing harness

Measures power-on → first ICMP reply on the Hadron board, power-cycled via the
ZUP PSU.

## Prereqs
- ZUP PSU wired to the board, reachable per `.env` (see zup-power-supply skill).
  Verify with: `python $ZUP_CTL status` (should print voltage/current).
- `bc` installed on host (`apt install bc`).
- `sshpass` installed for `collect-ondevice.sh`.
- Board flashed with the image under test; static IP 192.168.132.100 on eth0.

## Run
```bash
# 5 runs, record against a label
./measure-ping.sh 5 192.168.132.100 | tee /tmp/run.txt
./record.py --label baseline --phase 0 --n 5 \
  --sha "$(git rev-parse --short HEAD)" --notes "phase0 baseline" < /tmp/run.txt

# Per-stage breakdown once the board is up
./collect-ondevice.sh
```

## Interpreting
Keep a change only if `MEDIAN_MS` drops (or holds) vs the previous recorded run
AND the board still boots + answers ping. Otherwise `git revert` the experiment.

Results persist to `boot_runs.sqlite` in this directory (override with
`BOOT_RUNS_DB`). Query history:
```bash
python3 -c "import sqlite3;[print(r) for r in sqlite3.connect('boot_runs.sqlite').execute('select experiment_label,phase,median_ms,min_ms,notes from boot_runs order by id')]"
```

## Env vars
- `ZUP_CTL` — path to zup_control.py (default: skill path).
- `OFF_SETTLE` — seconds powered off before power-on (default 5).
- `MAX_WAIT` — per-run timeout seconds (default 120).
- `BOOT_RUNS_DB` — sqlite results path (default `./boot_runs.sqlite`).
