#!/usr/bin/env python3
# Verified RTT: unique incrementing marker each iteration, confirm echo matches.
import serial, time, sys, statistics, os, select

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 921600
N    = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
THR  = 5.0

ser = serial.Serial(PORT, BAUD, timeout=0.3)
try: ser.set_low_latency_mode(True)
except Exception: pass
fd = ser.fileno()

def wr(b):
    while True:
        try:
            os.write(fd, b); return
        except BlockingIOError:
            select.select([], [fd], [], 0.1)

def drain():
    while True:
        r,_,_ = select.select([fd], [], [], 0)
        if not r: break
        try:
            if not os.read(fd, 4096): break
        except OSError: break

# settle: fully empty the pipe
time.sleep(0.05); drain()

lat=[]; mism=0; lost=0
val=1
for i in range(N):
    drain()
    marker = bytes([val]); val = (val % 255) + 1  # 1..255, never 0
    t=time.perf_counter()
    wr(marker)
    got=None; deadline=t+0.3
    while time.perf_counter()<deadline:
        r,_,_=select.select([fd],[],[],deadline-time.perf_counter())
        if not r: break
        try: chunk=os.read(fd,1)
        except OSError: break
        if not chunk: break
        got=chunk[0]; break
    if got is None: lost+=1; continue
    dt=(time.perf_counter()-t)*1000.0
    if got!=marker[0]: mism+=1; continue   # stale/mismatched byte -> not our echo
    lat.append(dt)

lat.sort(); n=len(lat)
if n==0:
    print(f"no valid matched samples (lost={lost} mismatch={mism}) — check loopback"); sys.exit(2)
def pct(p): return lat[min(n-1,int(n*p))]
wire=(10.0/BAUD)*1000.0
print(f"port={PORT} baud={BAUD} matched={n} lost={lost} mismatch={mism}")
print(f"1-byte UART wire time x2 (physics floor) ~= {2*wire:.3f} ms")
print(f"min={lat[0]:.3f} avg={statistics.mean(lat):.3f} p50={pct(0.5):.3f} "
      f"p99={pct(0.99):.3f} p99.9={pct(0.999):.3f} max={lat[-1]:.3f} ms")
over=sum(1 for x in lat if x>THR)
print(f"> {THR} ms: {over} ({100*over/n:.3f}%)")
print("VERDICT:", "PASS" if lat[-1]<=THR else f"FAIL max={lat[-1]:.3f}ms")
