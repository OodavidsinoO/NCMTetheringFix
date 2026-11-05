#!/system/bin/sh
# Point USB tethering at CDC-NCM instead of RNDIS, and make the resulting
# netdev match the interface regex Tethering will use.
#
# Three facts drive this script. All come from static analysis of a OnePlus Open
# (CPH2551 / OP5973L1, Android 16) firmware; README.md records the evidence.
#
#  1. `tether_force_usb_functions` picks the USB function: 0 = RNDIS (stock),
#     1 = NCM. TetheringConfiguration reads it from Settings.Global and Tethering
#     watches it with a ContentObserver, so this is a live preference, not a
#     switch: nothing here starts tethering.
#
#  2. Firmwares that ship config_tether_ncm_regexs = ["ncm\d"] make
#     TetheringConfiguration swap the arrays: with the setting at 1,
#     tetherableUsbRegexs becomes that array and tetherableNcmRegexs is cleared.
#     The kernel names every f_ncm instance "usb%d", so "usb0" matches nothing
#     and no IpServer is started. Renaming the gadget interface fixes that.
#
#  3. Renaming is only correct when the firmware actually wants an ncm* name.
#     Without that overlay the USB regexs stay ["usb\d", "rndis\d"], where the
#     kernel default "usb0" already matches, and renaming would break a working
#     setup.
#
# The arrays are read from TetheringConfiguration.dump() rather than guessed from
# a build prop, because the dump reflects resources, static overlays and the
# setting as actually resolved. Both array lines are inspected so the check is
# idempotent: the overlay shows up in tetherableNcmRegexs while the setting is
# still 0, and in tetherableUsbRegexs once it is 1.
set -u

MODDIR=${0%/*}
LOG=$MODDIR/ncm-tethering.log
GLOBAL_KEY=tether_force_usb_functions

# Overridable so the logic can be exercised off-device.
GADGET_ROOT=${NCM_GADGET_ROOT:-/config/usb_gadget}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"
}

: >"$LOG"
log "start"

# Without an ncm function directory the firmware cannot expose CDC-NCM at all:
# init.qcom.usb.rc creates these in post-fs-data, and no "sys.usb.config=ncm"
# composition would exist. Selecting NCM there would leave the device with no
# working USB configuration, so refuse to touch anything.
have_ncm=0
for d in "$GADGET_ROOT"/*/functions/*.ncm* "$GADGET_ROOT"/*/functions/ncm.*; do
    if [ -d "$d" ]; then
        have_ncm=1
        break
    fi
done

if [ "$have_ncm" -eq 0 ]; then
    log "no ncm gadget function under $GADGET_ROOT; this firmware cannot do CDC-NCM"
    log "result: skipped"
    exit 0
fi

# A single dumpsys call, then pick out the two arrays TetheringConfiguration.dump()
# prints. No dumpsys "-a": that is a dumpsys-level flag, and Tethering.doDump()
# already prints the configuration for an empty argument list.
dump=$(dumpsys tethering 2>/dev/null || true)
usb_regexs=$(printf '%s\n' "$dump" | grep -m1 'tetherableUsbRegexs: ' || true)
ncm_regexs=$(printf '%s\n' "$dump" | grep -m1 'tetherableNcmRegexs: ' || true)

if [ -z "$usb_regexs" ] && [ -z "$ncm_regexs" ]; then
    # dumpsys may be unavailable very early in boot. Fall back to the static
    # signal: a shipped NCM overlay means the firmware expects an ncm* netdev.
    for dir in /product/overlay /system_ext/overlay /odm/overlay; do
        for apk in "$dir"/*[Nn][Cc][Mm]*; do
            [ -e "$apk" ] || continue
            ncm_regexs='tetherableNcmRegexs: (ncm overlay present)'
            break 2
        done
    done
    log "dumpsys gave no regexs; overlay probe: ${ncm_regexs:-inconclusive}"
fi

if [ -z "$usb_regexs" ] && [ -z "$ncm_regexs" ]; then
    # Unknown firmware: guessing could leave USB tethering unable to match any
    # interface. Leaving the setting untouched keeps stock RNDIS working.
    log "cannot determine expected interface regexs; leaving device untouched"
    log "result: skipped"
    exit 0
fi

log "${usb_regexs:-tetherableUsbRegexs: <unreadable>}"
log "${ncm_regexs:-tetherableNcmRegexs: <unreadable>}"

if printf '%s\n%s\n' "$usb_regexs" "$ncm_regexs" | grep -q ncm; then
    log "firmware expects an ncm* interface; renaming the gadget netdev"
    out=$(NCM_GADGET_ROOT="$GADGET_ROOT" sh "$MODDIR/ncm-ifname.sh" 2>&1)
    rc=$?
    printf '%s\n' "$out" | while IFS= read -r line; do log "$line"; done

    # Verify against the kernel, not against the helper's exit status.
    if [ "$rc" -ne 0 ] || ! cat "$GADGET_ROOT"/*/functions/ncm.*/ifname 2>/dev/null | grep -q '^ncm'; then
        log "no ncm* interface after rename; not selecting NCM (RNDIS tethering left intact)"
        log "result: failed"
        exit 1
    fi
else
    log "firmware matches the kernel default usb%d; leaving the interface alone"
fi

settings put global "$GLOBAL_KEY" 1
log "$GLOBAL_KEY=$(settings get global "$GLOBAL_KEY")"
log "result: ok"
