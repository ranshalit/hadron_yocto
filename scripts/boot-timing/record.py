#!/usr/bin/env python3
"""Record a measured boot run into the boot_runs table.
Usage: record.py --label OPT-x --phase 1 --median 12345 --min 12000 --n 5 \
         --sha $(git rev-parse --short HEAD) --notes "..."
Reads MEDIAN_MS/MIN_MS from stdin if --median omitted.
"""
import argparse
import sqlite3
import os
import sys


def find_db():
    return os.environ.get(
        "BOOT_RUNS_DB",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "boot_runs.sqlite"),
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--label", required=True)
    p.add_argument("--phase", default="")
    p.add_argument("--median", type=int)
    p.add_argument("--min", type=int, dest="min_ms")
    p.add_argument("--n", type=int, default=5)
    p.add_argument("--sha", default="")
    p.add_argument("--notes", default="")
    a = p.parse_args()

    median, min_ms = a.median, a.min_ms
    if median is None:
        for line in sys.stdin:
            if line.startswith("MEDIAN_MS="):
                median = int(line.strip().split("=", 1)[1])
            if line.startswith("MIN_MS="):
                min_ms = int(line.strip().split("=", 1)[1])

    db = find_db()
    os.makedirs(os.path.dirname(db), exist_ok=True)
    con = sqlite3.connect(db)
    con.execute(
        """CREATE TABLE IF NOT EXISTS boot_runs(
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT DEFAULT (datetime('now')),
        experiment_label TEXT NOT NULL, phase TEXT, median_ms INTEGER,
        min_ms INTEGER, n_runs INTEGER, git_sha TEXT, notes TEXT)"""
    )
    con.execute(
        "INSERT INTO boot_runs(experiment_label,phase,median_ms,min_ms,n_runs,git_sha,notes)"
        " VALUES (?,?,?,?,?,?,?)",
        (a.label, a.phase, median, min_ms, a.n, a.sha, a.notes),
    )
    con.commit()
    rows = list(
        con.execute(
            "SELECT experiment_label,phase,median_ms,min_ms FROM boot_runs ORDER BY id"
        )
    )
    print(f"Recorded {a.label}: median={median}ms min={min_ms}ms")
    print("History:")
    for r in rows:
        print(f"  {r[0]:24s} phase={str(r[1]):6s} median={r[2]}ms min={r[3]}ms")


if __name__ == "__main__":
    main()
