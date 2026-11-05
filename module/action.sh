#!/system/bin/sh
# KernelSU Action button. Tethering is unchanged by this module -- it only
# chooses which USB function tethering uses -- so point the user at the switch
# that matters and show the module's own state.
MODDIR=${0%/*}

echo "tether_force_usb_functions=$(/system/bin/settings get global tether_force_usb_functions)"
echo "expected usb function: $(/system/bin/settings get global tether_force_usb_functions | grep -qx 1 && echo NCM || echo RNDIS)"
echo
for f in /config/usb_gadget/*/functions/ncm.*/ifname; do
    [ -e "$f" ] || continue
    echo "ncm gadget ifname: $(cat "$f")"
done
echo
echo "--- last boot log ---"
cat "$MODDIR/ncm-tethering.log" 2>/dev/null || echo "(none)"
echo
echo "Opening tethering settings..."
exec /system/bin/am start --user current -a android.settings.TETHER_SETTINGS
