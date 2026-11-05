#!/system/bin/sh
# KernelSU Action button: report state, repair the one state that breaks USB
# tethering, then open the tethering settings.
#
# This module never enables tethering. All it owns is which USB function
# Tethering requests and, on firmwares with the NCM overlay, the gadget
# interface name. Those two must agree:
#
#   tether_force_usb_functions=1 + an ncm* interface  -> NCM tethering works
#   tether_force_usb_functions=1 + usb0               -> Tethering wants ncm\d,
#                                                        matches nothing, no DHCP
#   tether_force_usb_functions=0                      -> stock RNDIS
#
# The middle state is what a disabled module leaves behind: KernelSU runs no
# module scripts while a module is disabled, so boot-completed.sh never gets to
# rename the interface. Repair it here by dropping back to RNDIS, which always
# works with the kernel default name.
MODDIR=${0%/*}
GLOBAL_KEY=tether_force_usb_functions
GADGET_ROOT=${NCM_GADGET_ROOT:-/config/usb_gadget}

setting=$(/system/bin/settings get global "$GLOBAL_KEY" 2>/dev/null)
case "$setting" in
    1) echo "preferred function: NCM" ;;
    *[0-9]*) echo "preferred function: RNDIS (stock)" ;;
    *) echo "preferred function: unset; Tethering uses the resource default (RNDIS)" ;;
esac

echo
ifnames=$(cat "$GADGET_ROOT"/*/functions/ncm.*/ifname 2>/dev/null)
if [ -z "$ifnames" ]; then
    echo "ncm gadget: not present on this firmware"
else
    echo "ncm gadget interface: $(printf '%s' "$ifnames" | tr '\n' ' ')"
fi

if [ "$setting" = 1 ] && [ -n "$ifnames" ] && ! printf '%s' "$ifnames" | grep -q '^ncm'; then
    echo
    echo "Mismatch: NCM is selected but the interface is not named ncm*."
    echo "Tethering would match no interface, which is what a disabled module leaves behind."
    echo "Reverting to RNDIS so USB tethering keeps working."
    /system/bin/settings delete global "$GLOBAL_KEY"
    echo "Reverted. Re-enable the module and reboot to use NCM again."
fi

echo
echo "--- last boot log ---"
cat "$MODDIR/ncm-tethering.log" 2>/dev/null || echo "(none)"
echo
echo "Opening tethering settings..."
exec /system/bin/am start --user current -a android.settings.TETHER_SETTINGS
