#!/bin/busybox sh
#
# init-phase2-multi.sh — RAM-resident MULTI-PARTITION NVMe flasher initramfs.
#
# This is the multi-partition successor to the skill's single-partition
# init-phase2.sh. It flashes a SET of NVMe partitions (rootfs/APP + ESP + A/B
# kernel/dtb, etc.) in one boot, reusing the same safety model:
#
#   stage-on-disk  ->  copy-to-RAM  ->  unmount root  ->  verify EVERY sha256
#   (the GATE — nothing is written until ALL images pass)  ->  dd each to its
#   partition  ->  sync + reboot.
#
# Safety model (read before changing anything):
#   1. Every image was staged on the device's rootfs and sha-verified there
#      before reboot. Paths/shas/targets are baked into the @MANIFEST@ below.
#   2. Root is mounted READ-ONLY; we COPY every staged image into RAM. Once all
#      copies are in RAM we no longer need the disk's filesystem, so we can
#      unmount root and overwrite any partition (including APP, the very
#      partition the images were read from).
#   3. We unmount root so dd has exclusive ownership.
#   4. THE GATE: we verify the sha256 of EVERY RAM copy (decompressed for .gz)
#      against the manifest BEFORE touching any partition. A single mismatch
#      self-heals (restore stock boot, reboot) — disk untouched.
#   5. Only then do we dd each image to its target partition. The manifest is
#      ORDERED so the small boot-critical partitions (ESP, kernels) are written
#      first and complete fast; the large APP/rootfs is written LAST, so that
#      the longest (most power-exposed) write lands on the partition that can be
#      re-flashed without bricking (QSPI+ESP remain intact if it fails).
#   6. The single point of no return is the FIRST dd. From there until the final
#      sync, a power loss can brick the board — do NOT cut power.
#
# selfheal()/rescue() are identical in spirit to init-phase2.sh and are valid
# ONLY before the first dd.
#
# Placeholders substituted by the orchestrator (flash_eth_initrd.sh):
#   @ROOT_DEV@    the rootfs partition, mounted RO to read the staged images
#                 (e.g. /dev/nvme0n1p1)
#   @EXTLINUX@    path to extlinux.conf relative to mounted root, for self-heal
#   @MANIFEST@    one `add_entry` call per partition to flash (see below). Each:
#                 add_entry LABEL TARGET_DEV STAGE_PATH SHA256 COMPRESSED
#                   LABEL       short name for logs + RAM filename
#                   TARGET_DEV  absolute device node to dd onto (e.g. /dev/nvme0n1p10)
#                   STAGE_PATH  staged image path relative to mounted root (e.g. /flash/esp.img)
#                   SHA256      sha256 of the RAW (decompressed) image
#                   COMPRESSED  1 if STAGE_PATH is gzip (.gz), else 0

ROOT_DEV="@ROOT_DEV@"
EXTLINUX="@EXTLINUX@"

/bin/busybox mkdir -p /proc /sys /dev /newroot /ram
/bin/mount -t proc proc /proc 2>/dev/null
/bin/mount -t sysfs sysfs /sys 2>/dev/null
/bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null

msg(){ echo "[flash] $*" > /dev/console 2>/dev/null; \
       echo "[flash] $*" > /dev/ttyTCU0 2>/dev/null; \
       echo "[flash] $*" > /dev/ttyTHS0 2>/dev/null; }

# Restore stock boot + reboot. Safe ONLY before the first dd, and ONLY if the
# restore verifiably succeeds (else a reboot re-enters this flasher forever).
selfheal(){
    msg "SELF-HEAL: $1 — restoring stock boot, disk untouched"
    if /bin/mount -o remount,rw /newroot 2>/dev/null \
       && [ -f "/newroot${EXTLINUX}.orig" ] \
       && /bin/busybox cp "/newroot${EXTLINUX}.orig" "/newroot${EXTLINUX}"; then
        /bin/busybox sync; /bin/busybox sleep 2; /bin/busybox reboot -f
    fi
    rescue "selfheal could not restore stock boot (reboot would loop)"
}

# Disk unreachable / can't restore extlinux: a reboot would re-enter this
# flasher forever. Drop to a serial shell instead of looping.
rescue(){
    msg "RESCUE: $1"
    msg "NOT rebooting (would loop on this flasher). Recover via USB/RCM or fix"
    msg "extlinux on the rootfs, then reboot. Dropping to a serial shell."
    /bin/busybox sync
    exec /bin/busybox sh -i </dev/console >/dev/console 2>&1
    while true; do /bin/busybox sleep 3600; done
}

# ── manifest ────────────────────────────────────────────────────────────────
# The orchestrator replaces @MANIFEST@ with one add_entry line per partition.
# We accumulate the entries into space-separated lists (busybox sh has no
# arrays) and iterate by index. Order of add_entry calls == write order.
N=0
LABELS=""; TARGETS=""; STAGES=""; SHAS=""; COMPS=""
add_entry(){
    # $1 label  $2 target_dev  $3 stage_path  $4 sha256  $5 compressed
    LABELS="$LABELS $1"; TARGETS="$TARGETS $2"; STAGES="$STAGES $3"
    SHAS="$SHAS $4"; COMPS="$COMPS $5"
    N=$((N+1))
}

# field N of a space-separated list.
# NOTE: capture the index ($2) BEFORE `set -- $1`, which overwrites the
# positional params (so $2 would otherwise become the 2nd list element).
field(){ # $1 list  $2 index(1-based)
    _fi="$2"
    set -- $1
    eval "echo \"\${${_fi}}\""
}

@MANIFEST@

[ "$N" -gt 0 ] || rescue "empty flash manifest (nothing to do)"
msg "multi-partition flasher: $N partition(s) to write."

# ── wait for the rootfs device (NVMe enumeration) ───────────────────────────
i=0
while [ ! -b "$ROOT_DEV" ] && [ $i -lt 150 ]; do /bin/busybox sleep 0.2; i=$((i+1)); done
[ -b "$ROOT_DEV" ] || rescue "$ROOT_DEV absent (NVMe not enumerated?)"

# ── mount root RO + copy every staged image into RAM ────────────────────────
if ! /bin/mount -o ro "$ROOT_DEV" /newroot; then
    rescue "cannot mount root $ROOT_DEV read-only"
fi

# RAM headroom pre-check: sum of staged (on-disk, possibly compressed) sizes.
TOTAL_STAGED=0
idx=1
while [ $idx -le $N ]; do
    st="$(field "$STAGES" $idx)"
    sz="$(/bin/busybox stat -c %s "/newroot${st}" 2>/dev/null)"
    [ -n "$sz" ] || sz="$(/bin/busybox wc -c < "/newroot${st}" 2>/dev/null)"
    [ -n "$sz" ] || sz=0
    TOTAL_STAGED=$(( TOTAL_STAGED + sz ))
    idx=$((idx+1))
done
MEM_AVAIL_KB="$(/bin/busybox sed -n 's/^MemAvailable:[ \t]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)"
[ -n "$MEM_AVAIL_KB" ] || MEM_AVAIL_KB="$(/bin/busybox sed -n 's/^MemFree:[ \t]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)"
if [ -n "$MEM_AVAIL_KB" ]; then
    MEM_AVAIL_BYTES=$(( MEM_AVAIL_KB * 1024 ))
    NEED_BYTES=$(( TOTAL_STAGED + 134217728 ))   # staged total + ~128MiB headroom
    msg "RAM check: need ~${NEED_BYTES}B for staged copies, available ${MEM_AVAIL_BYTES}B"
    if [ "$MEM_AVAIL_BYTES" -lt "$NEED_BYTES" ] 2>/dev/null; then
        selfheal "insufficient RAM: need ~${NEED_BYTES}B, have ${MEM_AVAIL_BYTES}B"
    fi
fi

idx=1
while [ $idx -le $N ]; do
    lbl="$(field "$LABELS" $idx)"; st="$(field "$STAGES" $idx)"
    if [ ! -f "/newroot${st}" ]; then
        selfheal "staged image /newroot${st} ($lbl) not found"
    fi
    msg "copying $lbl into RAM ($st)"
    if ! /bin/busybox cp "/newroot${st}" "/ram/${lbl}"; then
        selfheal "copy to RAM failed for $lbl (out of memory?)"
    fi
    idx=$((idx+1))
done

# ── unmount root so dd owns the partitions exclusively ──────────────────────
/bin/busybox sync
if ! /bin/umount /newroot; then
    /bin/umount -l /newroot 2>/dev/null || selfheal "could not unmount root"
fi

# ── THE GATE: verify sha256 of EVERY RAM copy BEFORE any dd ─────────────────
idx=1
while [ $idx -le $N ]; do
    lbl="$(field "$LABELS" $idx)"; sha="$(field "$SHAS" $idx)"; comp="$(field "$COMPS" $idx)"
    msg "verifying sha256 of $lbl ..."
    if [ "$comp" = "1" ]; then
        if ! /bin/busybox gunzip -t "/ram/${lbl}" 2>/dev/null; then
            /bin/mount "$ROOT_DEV" /newroot 2>/dev/null
            selfheal "gzip integrity check failed for $lbl"
        fi
        got="$(/bin/busybox gunzip -c "/ram/${lbl}" | /bin/busybox sha256sum | /bin/busybox cut -d' ' -f1)"
    else
        got="$(/bin/busybox sha256sum "/ram/${lbl}" | /bin/busybox cut -d' ' -f1)"
    fi
    if [ "$got" != "$sha" ]; then
        /bin/mount "$ROOT_DEV" /newroot 2>/dev/null
        selfheal "sha256 MISMATCH for $lbl: got=$got want=$sha"
    fi
    idx=$((idx+1))
done

# ── capacity gate: each raw image must fit its target partition ─────────────
idx=1
while [ $idx -le $N ]; do
    lbl="$(field "$LABELS" $idx)"; tgt="$(field "$TARGETS" $idx)"; comp="$(field "$COMPS" $idx)"
    if [ "$comp" = "1" ]; then
        raw="$(/bin/busybox gunzip -c "/ram/${lbl}" 2>/dev/null | /bin/busybox wc -c)"
    else
        raw="$(/bin/busybox stat -c %s "/ram/${lbl}" 2>/dev/null)"
        [ -n "$raw" ] || raw="$(/bin/busybox wc -c < "/ram/${lbl}")"
    fi
    tname="$(/bin/busybox basename "$tgt")"
    tsec="$(/bin/busybox cat "/sys/class/block/$tname/size" 2>/dev/null)"
    if [ -n "$tsec" ] && [ "$tsec" -gt 0 ] 2>/dev/null; then
        tbytes=$(( tsec * 512 ))
        msg "capacity $lbl: image=${raw}B target=${tbytes}B ($tgt)"
        if [ -n "$raw" ] && [ "$raw" != "0" ] && [ "$raw" -gt "$tbytes" ] 2>/dev/null; then
            /bin/mount "$ROOT_DEV" /newroot 2>/dev/null
            selfheal "image too large for $tgt: ${raw}B > ${tbytes}B ($lbl)"
        fi
    else
        msg "WARNING: could not read size of $tgt — capacity gate skipped for $lbl"
    fi
    idx=$((idx+1))
done

msg "ALL images verified. Beginning writes — POINT OF NO RETURN, do not cut power."

# ── writes (ordered; APP/rootfs last via manifest order) ────────────────────
idx=1
while [ $idx -le $N ]; do
    lbl="$(field "$LABELS" $idx)"; tgt="$(field "$TARGETS" $idx)"; comp="$(field "$COMPS" $idx)"
    msg "[$idx/$N] writing $lbl -> $tgt (compressed=$comp)"
    if [ "$comp" = "1" ]; then
        /bin/busybox gunzip -c "/ram/${lbl}" | /bin/busybox dd of="$tgt" bs=1M
        rc=$?
    else
        /bin/busybox dd if="/ram/${lbl}" of="$tgt" bs=1M
        rc=$?
    fi
    if [ "$rc" != "0" ]; then
        msg "FATAL: dd failed writing $lbl -> $tgt. Partition partially written."
        msg "DO NOT power off. Re-run the flasher or recover via USB if available."
        /bin/busybox sync
        while true; do /bin/busybox sleep 60; done
    fi
    /bin/busybox sync
    idx=$((idx+1))
done

/bin/busybox sync
msg "all $N partition(s) flashed. Rebooting into the new image."
/bin/busybox sleep 2
/bin/busybox reboot -f
