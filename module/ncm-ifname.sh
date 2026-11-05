#!/system/bin/sh
# Rename the NCM gadget netdev from the kernel default "usb0" to "ncm0".
#
# The kernel builds the name with snprintf(net->name, IFNAMSIZ, "%s%%d", "usb")
# in gether_setup_name_default(), called from ncm_alloc_inst(). Firmwares whose
# tethering resources expect "ncm\d" therefore never match the interface.
#
# configfs exposes functions/ncm.0/ifname for exactly this. The validator
# (gether_set_ifname) requires a literal "%d" placeholder -- "ncm0" is rejected
# with EINVAL, "ncm%d" is accepted -- and the attribute returns EBUSY once the
# function has been bound into a configuration, so retry while idle.
set -eu

# Overridable so the logic can be exercised off-device.
GADGET_ROOT=${NCM_GADGET_ROOT:-/config/usb_gadget}
WANT='ncm%d'

log() { echo "ncm-ifname: $*"; }

found=0
for gadget in "$GADGET_ROOT"/*/functions/*.ncm* "$GADGET_ROOT"/*/functions/ncm.*; do
    [ -d "$gadget" ] || continue
    ifname=$gadget/ifname

    if [ ! -e "$ifname" ]; then
        log "$gadget has no ifname attribute, skipping"
        continue
    fi

    found=1
    current=$(cat "$ifname" 2>/dev/null || true)

    case "$current" in
        ncm*)
            log "$gadget already $current"
            continue
            ;;
    esac

    # ifname_store returns EBUSY while opts->refcnt != 0, i.e. while the
    # function is symlinked into a configuration. boot-completed normally runs
    # long before tethering starts, so this loop only covers the race with a
    # user who already enabled it; 5 x 2s stays well under the stage timeout.
    i=0
    while [ "$i" -lt 5 ]; do
        if printf '%s' "$WANT" >"$ifname" 2>/dev/null; then
            log "$gadget renamed ${current:-<default>} -> $(cat "$ifname" 2>/dev/null)"
            break
        fi
        i=$((i + 1))
        [ "$i" -lt 5 ] && sleep 2
    done

    if [ "$i" -ge 5 ]; then
        log "$gadget refused $WANT after $i attempts (still ${current:-<default>})"
        exit 1
    fi
done

if [ "$found" -eq 0 ]; then
    log "no NCM gadget function directory found"
    exit 1
fi

exit 0
