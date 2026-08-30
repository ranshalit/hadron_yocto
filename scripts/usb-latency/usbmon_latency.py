#!/usr/bin/env python3
# Parse usbmon text stream: pair URB Submit(S) with Complete(C) by URB tag,
# report per-endpoint submit->complete latency distribution (host USB service time).
import sys, collections, statistics

pending = {}                      # urb_tag -> (ts_us, ep_key)
lat = collections.defaultdict(list)
for line in sys.stdin:
    f = line.split()
    if len(f) < 4:
        continue
    tag, ts, ev, addr = f[0], f[1], f[2], f[3]   # addr like 'Ii:3:015:1'
    try:
        ts = int(ts)
    except ValueError:
        continue
    if ev == 'S':
        pending[tag] = (ts, addr)
    elif ev == 'C' and tag in pending:
        ts0, ep = pending.pop(tag)
        dt_ms = (ts - ts0) / 1000.0
        if dt_ms >= 0:
            lat[ep].append(dt_ms)

def pct(a, p): return a[min(len(a)-1, int(len(a)*p))]
print(f"{'endpoint':<16}{'n':>7}{'min':>9}{'avg':>9}{'p50':>9}{'p99':>9}{'p99.9':>9}{'max':>9}  over5ms")
for ep, a in sorted(lat.items()):
    if not a: continue
    a.sort()
    over = sum(1 for x in a if x > 5.0)
    print(f"{ep:<16}{len(a):>7}{a[0]:>9.3f}{statistics.mean(a):>9.3f}"
          f"{pct(a,0.5):>9.3f}{pct(a,0.99):>9.3f}{pct(a,0.999):>9.3f}{a[-1]:>9.3f}"
          f"  {over} ({100*over/len(a):.2f}%)")
