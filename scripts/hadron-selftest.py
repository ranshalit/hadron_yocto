#!/usr/bin/env python3
"""Hadron NGX012 interface self-test.

Host-side smoke test. SSHes into the device and verifies that all hardware
interfaces are functional: ethernet, USB host ports, UVC camera, ttyCAM /
ttyPixHawk serial links, onboard serial console, and the BMI160 IMU.

Non-interactive: runs once, prints a colored PASS/WARN/FAIL table (or --json),
exits 0 (no FAIL), 1 (a FAIL), or 2 (device unreachable).

Config comes from the environment then a .env in the current directory:
  DEVICE_IP, DEVICE_SSH_USER, DEVICE_SSH_PASS, DEVICE_SSH_CONNECT_TIMEOUT
CLI flags override: --ip --user --password --timeout --only --json
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

PASS, WARN, FAIL = "PASS", "WARN", "FAIL"

COLOR = {
    PASS: "\033[32m",
    WARN: "\033[33m",
    FAIL: "\033[31m",
}
RESET = "\033[0m"

EXPECTED_IP = "192.168.132.100"


class CheckResult:
    def __init__(self, name, status, detail=""):
        self.name = name
        self.status = status
        self.detail = detail

    def as_dict(self):
        return {"name": self.name, "status": self.status, "detail": self.detail}


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #

def load_dotenv(path=".env"):
    """Return a dict of KEY=VALUE pairs from a .env file (no shell sourcing)."""
    env = {}
    if not os.path.isfile(path):
        return env
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            env[key] = val
    return env


def resolve_config(args):
    dotenv = load_dotenv()

    def pick(cli, key, default=None):
        if cli is not None:
            return cli
        if os.environ.get(key):
            return os.environ[key]
        if dotenv.get(key):
            return dotenv[key]
        return default

    cfg = {
        "ip": pick(args.ip, "DEVICE_IP"),
        "user": pick(args.user, "DEVICE_SSH_USER"),
        "password": pick(args.password, "DEVICE_SSH_PASS"),
        "connect_timeout": pick(None, "DEVICE_SSH_CONNECT_TIMEOUT", "10"),
        "timeout": args.timeout,
    }
    missing = [k for k in ("ip", "user", "password") if not cfg[k]]
    if missing:
        keymap = {"ip": "DEVICE_IP", "user": "DEVICE_SSH_USER",
                  "password": "DEVICE_SSH_PASS"}
        names = ", ".join(keymap[k] for k in missing)
        sys.exit(f"error: missing required config: {names} "
                 "(set in .env, environment, or via CLI flags)")
    return cfg


# --------------------------------------------------------------------------- #
# Remote execution
# --------------------------------------------------------------------------- #

class Device:
    def __init__(self, cfg):
        self.cfg = cfg
        if not shutil.which("sshpass"):
            sys.exit("error: sshpass not found on host "
                     "(install with: sudo apt install sshpass)")

    def remote(self, cmd, timeout=None, sudo=False):
        """Run cmd on the device. Returns (rc, stdout, stderr).

        When sudo=True the command runs under `sudo -S`, with the SSH password
        fed on stdin (the ubuntu user is not in the video/dialout groups, so the
        device-node I/O checks need root).
        """
        timeout = timeout or self.cfg["timeout"]
        stdin_data = None
        if sudo:
            cmd = f"sudo -S -p '' {cmd}"
            stdin_data = self.cfg["password"] + "\n"
        ssh = [
            "sshpass", "-p", self.cfg["password"],
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", f"ConnectTimeout={self.cfg['connect_timeout']}",
            f"{self.cfg['user']}@{self.cfg['ip']}",
            cmd,
        ]
        try:
            proc = subprocess.run(ssh, capture_output=True, text=True,
                                  input=stdin_data, timeout=timeout)
            return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
        except subprocess.TimeoutExpired:
            return 124, "", f"command timed out after {timeout}s"

    def preflight(self):
        """Confirm the device is reachable. Returns (ok, message)."""
        ping = subprocess.run(["ping", "-c1", "-W2", self.cfg["ip"]],
                              capture_output=True, text=True)
        if ping.returncode != 0:
            return False, f"host ping to {self.cfg['ip']} failed"
        rc, out, err = self.remote("echo ok", timeout=self.cfg["timeout"])
        if rc == 0 and out == "ok":
            return True, ""
        blob = (err or out).lower()
        conn_errs = ("connection refused", "connection timed out",
                     "no route to host", "network is unreachable",
                     "could not resolve hostname", "timed out")
        auth_errs = ("permission denied", "host key verification")
        if any(e in blob for e in auth_errs):
            return False, f"SSH auth failed: {err or out}"
        if any(e in blob for e in conn_errs):
            return False, f"SSH unreachable: {err or out}"
        return False, f"SSH failed (rc={rc}): {err or out}"


# --------------------------------------------------------------------------- #
# Checks — each returns a CheckResult
# --------------------------------------------------------------------------- #

def check_ethernet(dev):
    rc, out, err = dev.remote("ip -br addr show eth0")
    if rc != 0 or not out:
        return CheckResult("ethernet", FAIL, f"eth0 query failed: {err or 'no output'}")
    fields = out.split()
    state = fields[1] if len(fields) > 1 else "?"
    has_ip = EXPECTED_IP in out
    if state.upper() != "UP":
        return CheckResult("ethernet", FAIL, f"eth0 state {state}")
    if not has_ip:
        return CheckResult("ethernet", FAIL,
                           f"eth0 UP but IP != {EXPECTED_IP} ({out})")
    return CheckResult("ethernet", PASS, f"eth0 UP {EXPECTED_IP}, host ping ok")


def check_usb_ports(dev):
    # Root hubs are usbN entries. Real downstream devices are counted from lsusb
    # (excluding root hubs); sysfs port entries like "1-0:1.0" are hub interfaces,
    # not attached devices, so they must not be counted.
    cmd = (r"ls /sys/bus/usb/devices/ | grep -E '^usb[0-9]+$' | wc -l; "
           r"lsusb 2>/dev/null | grep -v 'root hub' | wc -l")
    rc, out, err = dev.remote(cmd)
    if rc != 0:
        return CheckResult("usb_ports", FAIL, f"sysfs query failed: {err}")
    try:
        hubs, devices = (int(x) for x in out.split())
    except ValueError:
        return CheckResult("usb_ports", FAIL, f"unexpected output: {out!r}")
    if hubs < 2:
        return CheckResult("usb_ports", FAIL,
                           f"expected >=2 xHCI root hubs, found {hubs}")
    if devices == 0:
        return CheckResult("usb_ports", WARN,
                           f"{hubs} xHCI controllers up, no device attached")
    return CheckResult("usb_ports", PASS,
                       f"{hubs} controllers up, {devices} device(s) attached")


UVC_SNIPPET = r'''
import sys
dev = "/dev/video0"
try:
    from linuxpy.video.device import Device
    with Device(dev) as d:
        for frame in d:
            print("FRAME", len(bytes(frame)))
            break
    sys.exit(0)
except Exception as e1:
    try:
        import warnings
        warnings.filterwarnings("ignore")
        from v4l2py import Device
        with Device.from_id(0) as cam:
            for frame in cam:
                print("FRAME", len(bytes(frame)))
                break
        sys.exit(0)
    except Exception as e2:
        print("ERR", repr(e1), "|", repr(e2))
        sys.exit(1)
'''


def check_uvc_cam(dev):
    rc, out, _ = dev.remote("ls /dev/video0 2>/dev/null")
    if rc != 0 or not out:
        return CheckResult("uvc_cam", WARN, "no /dev/video0 (camera not attached?)")
    rc, out, err = dev.remote(f"python3 -c {shell_quote(UVC_SNIPPET)}",
                              timeout=20, sudo=True)
    if rc == 0 and out.startswith("FRAME"):
        parts = out.split()
        size = parts[1] if len(parts) > 1 else "?"
        return CheckResult("uvc_cam", PASS, f"/dev/video0 frame captured ({size} bytes)")
    return CheckResult("uvc_cam", FAIL,
                       f"/dev/video0 present but capture failed: {out or err}")


def check_tty_cam(dev):
    rc, _, _ = dev.remote("test -e /dev/ttyCAM")
    if rc == 0:
        return CheckResult("tty_cam", PASS, "/dev/ttyCAM present")
    return CheckResult("tty_cam", WARN, "/dev/ttyCAM absent (UART camera not attached?)")


PIXHAWK_SNIPPET = r'''
import sys
try:
    from pymavlink import mavutil
    m = mavutil.mavlink_connection("/dev/ttyPixHawk", baud=115200)
    hb = m.wait_heartbeat(timeout=6)
    if hb is not None:
        print("HB", getattr(hb, "type", "?"))
        sys.exit(0)
    print("NOHB")
    sys.exit(1)
except Exception as e:
    print("ERR", repr(e))
    sys.exit(1)
'''


def check_tty_pixhawk(dev):
    rc, _, _ = dev.remote("test -e /dev/ttyPixHawk")
    if rc != 0:
        return CheckResult("tty_pixhawk", WARN,
                           "/dev/ttyPixHawk absent (flight controller not attached?)")
    rc, out, err = dev.remote(f"python3 -c {shell_quote(PIXHAWK_SNIPPET)}",
                              timeout=15, sudo=True)
    if rc == 0 and out.startswith("HB"):
        return CheckResult("tty_pixhawk", PASS, f"MAVLink heartbeat received ({out})")
    return CheckResult("tty_pixhawk", FAIL,
                       f"/dev/ttyPixHawk present but no heartbeat: {out or err}")


def check_onboard_serial(dev):
    rc, _, _ = dev.remote("test -e /dev/ttyTHS1")
    if rc == 0:
        return CheckResult("onboard_serial", PASS, "/dev/ttyTHS1 present")
    return CheckResult("onboard_serial", FAIL, "/dev/ttyTHS1 absent")


def check_imu(dev):
    # Find an iio device whose name contains bmi160, then read one raw sample.
    cmd = (r"for d in /sys/bus/iio/devices/iio:device*; do "
           r"[ -e \"$d/name\" ] || continue; "
           r"n=$(cat \"$d/name\"); "
           r"case \"$n\" in *bmi160*) echo \"$d $n\"; "
           r"cat \"$d/in_accel_x_raw\" 2>/dev/null; exit 0;; esac; "
           r"done; exit 3")
    rc, out, err = dev.remote(cmd)
    if rc == 3 or not out:
        return CheckResult("imu", WARN, "no BMI160 iio device (IMU not present?)")
    if rc != 0:
        return CheckResult("imu", FAIL, f"BMI160 present but read failed: {err or out}")
    lines = out.splitlines()
    dev_line = lines[0] if lines else "?"
    sample = lines[1] if len(lines) > 1 else "?"
    return CheckResult("imu", PASS, f"{dev_line}, accel_x_raw={sample}")


CHECKS = {
    "ethernet": check_ethernet,
    "usb_ports": check_usb_ports,
    "uvc_cam": check_uvc_cam,
    "tty_cam": check_tty_cam,
    "tty_pixhawk": check_tty_pixhawk,
    "onboard_serial": check_onboard_serial,
    "imu": check_imu,
}


# --------------------------------------------------------------------------- #
# Helpers / reporting
# --------------------------------------------------------------------------- #

def shell_quote(s):
    """Single-quote a string for safe use in a remote shell command."""
    return "'" + s.replace("'", "'\"'\"'") + "'"


def render_table(results, use_color):
    name_w = max((len(r.name) for r in results), default=5)
    lines = []
    for r in results:
        status = r.status
        if use_color:
            status = f"{COLOR[r.status]}{r.status}{RESET}"
        lines.append(f"  {r.name.ljust(name_w)}  {status}  {r.detail}")
    counts = {PASS: 0, WARN: 0, FAIL: 0}
    for r in results:
        counts[r.status] += 1
    summary = f"{counts[PASS]} PASS, {counts[WARN]} WARN, {counts[FAIL]} FAIL"
    lines.append("")
    lines.append(f"  {summary}")
    return "\n".join(lines)


def render_json(cfg, results, exit_code):
    counts = {PASS: 0, WARN: 0, FAIL: 0}
    for r in results:
        counts[r.status] += 1
    payload = {
        "device": cfg["ip"],
        "results": [r.as_dict() for r in results],
        "summary": {"pass": counts[PASS], "warn": counts[WARN],
                    "fail": counts[FAIL]},
        "exit_code": exit_code,
    }
    return json.dumps(payload, indent=2)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main():
    ap = argparse.ArgumentParser(description="Hadron NGX012 interface self-test")
    ap.add_argument("--ip", help="device IP (default: DEVICE_IP)")
    ap.add_argument("--user", help="SSH user (default: DEVICE_SSH_USER)")
    ap.add_argument("--password", help="SSH password (default: DEVICE_SSH_PASS)")
    ap.add_argument("--timeout", type=int, default=20,
                    help="per-check timeout in seconds (default: 20)")
    ap.add_argument("--only", help="comma-separated subset of checks to run "
                    f"({', '.join(CHECKS)})")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = ap.parse_args()

    cfg = resolve_config(args)

    if args.only:
        wanted = [c.strip() for c in args.only.split(",") if c.strip()]
        unknown = [c for c in wanted if c not in CHECKS]
        if unknown:
            sys.exit(f"error: unknown check(s): {', '.join(unknown)}")
        selected = wanted
    else:
        selected = list(CHECKS)

    dev = Device(cfg)
    ok, msg = dev.preflight()
    if not ok:
        if args.json:
            print(json.dumps({"device": cfg["ip"], "error": msg, "exit_code": 2},
                             indent=2))
        else:
            print(f"device unreachable: {msg}", file=sys.stderr)
        sys.exit(2)

    results = []
    for name in selected:
        try:
            results.append(CHECKS[name](dev))
        except Exception as exc:  # a check must never crash the run
            results.append(CheckResult(name, FAIL, f"internal error: {exc!r}"))

    exit_code = 1 if any(r.status == FAIL for r in results) else 0

    use_color = sys.stdout.isatty()
    if args.json:
        print(render_json(cfg, results, exit_code))
    else:
        print(f"Hadron interface self-test — {cfg['ip']}")
        print(render_table(results, use_color))

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
