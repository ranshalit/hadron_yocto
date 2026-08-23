# Boot-till-ping attribution (single TCU0 cable, grabserial)

Captured after reverting the TCU0->THS1 console redirect (commit c8bee4d) so the
Linux kernel console shares TCU0 with the bootloader firmware. One grabserial
cable therefore timestamps the *entire* MB1 -> UEFI -> kernel -> systemd chain.

Method: `scripts/boot-timing/grabserial-profile.sh` power-cycles via the ZUP PSU
and starts grabserial with base time = launch; PSU powers on ~0.3s later. All wall
times below are grabserial seconds (subtract ~0.3s for true power-on origin).
Ping becomes possible at L2 **eth0 link up** (static IP is already set, so
systemd-networkd-wait-online does NOT gate ICMP).

Log: `/tmp/grab-tcu0-full.txt` (kept out of git; 1746 lines).

| Stage | Wall (s) | Delta | Attribution |
|---|---|---|---|
| Power-on (PSU on) | 0.3 | -- | |
| MB1 first UART print | 3.9 | +3.6 | BootROM + PMIC ramp before MB1 (mostly fixed HW) |
| UEFI firmware banner | 7.9 | +4.0 | MB1 -> MB2 -> BPMP -> UEFI handoff |
| UEFI "System firmware version" + Direct Boot | 14.6 | **+6.7** | UEFI device init / PCIe/USB enum / boot scan |
| EFI stub "Booting Linux Kernel" | 20.2 | **+5.6** | load kernel Image + initrd from ESP (FAT) |
| Kernel [0.000000] Booting Linux | 23.7 | +3.5 | ExitBootServices + kernel decompress/handoff |
| eth0 (r8168) registered, IRQ 254 | 30.6 | +6.9 | kernel driver probe up to NIC (k10.25s) |
| **eth0 LINK UP (PING POSSIBLE)** | **34.8** | **+4.0** | r8168 PHY autonegotiation (k14.41s) |
| login prompt | 36.5 | +1.8 | userspace to getty |

## Budget summary (~34.8s to ping)
- Pre-kernel firmware/UEFI: **~23.4s (67%)**
  - BootROM/PMIC: 3.6s (fixed)
  - MB1->UEFI: 4.0s
  - UEFI init/scan: **6.7s**  <-- lever
  - Direct-Boot load Image+initrd: **5.6s**  <-- lever (initrd)
  - ExitBootServices->kernel: 3.5s
- Kernel start -> eth0 link up: **~11.4s**
  - kernel -> NIC driver probe: 10.25s  <-- driver strip / built-in NIC
  - PHY autoneg (register->link up): **4.0s**  <-- lever

## Prioritized levers (by measured cost)
1. **UEFI init/scan 6.7s + EFI-stub load 5.6s (~12s)** — the single biggest block.
   Kill the initrd (needs NVMe+NIC built-in first), trim UEFI boot timeout, disable
   unused UEFI boot paths (PXE/HTTP/USB scan), quiet firmware. Requires QSPI/UEFI
   rebuild + full flash to test.
2. **Kernel -> eth0 probe 10.25s** — driver strip, built-in NIC/NVMe (=y), reduce
   deferred-probe churn.
3. **PHY autoneg 4.0s** — force link speed / PHY tuning (partly switch/cable bound).

Note: this capture ran with `console=ttyTCU0` and NON-quiet kernel log, which adds
serial-print overhead; treat these as attribution, not the KPI number. KPI runs use
the quiet THS1 config via measure-ping.sh.
