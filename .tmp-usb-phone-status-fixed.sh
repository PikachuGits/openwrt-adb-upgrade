#!/bin/sh
echo '{"phones":['
first=true
for iface in /sys/class/net/usb*; do
    [ -d "$iface" ] || continue
    name=$(basename "$iface")
    device_path=$(readlink -f "$iface/device" 2>/dev/null)
    usb_port=$(echo "$device_path" | grep -oE '[0-9]+-[0-9]+(\.[0-9]+)?' | tail -1)
    mac=$(cat "$iface/address" 2>/dev/null)
    ip=$(ip addr show "$name" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

    cfg_line=$(uci show usb_port_manager 2>/dev/null | grep "usb_port='$usb_port'" | head -1)
    cfg_section=$(echo "$cfg_line" | sed "s/usb_port_manager\.//; s/\.usb_port=.*//")
    cfg_alias=$(uci show usb_port_manager 2>/dev/null | grep "usb_port='$usb_port'" -A5 | grep 'alias' | head -1 | cut -d"'" -f2)
    cfg_ip=$(uci show usb_port_manager 2>/dev/null | grep "usb_port='$usb_port'" -A5 | grep 'target_ip' | head -1 | cut -d"'" -f2)
    cfg_note=$(uci show usb_port_manager 2>/dev/null | grep "usb_port='$usb_port'" -A5 | grep 'note' | head -1 | cut -d"'" -f2)

    [ -z "$cfg_section" ] && cfg_section=""
    [ -z "$cfg_alias" ] && cfg_alias="$name"
    [ -z "$cfg_ip" ] && cfg_ip=""
    [ -z "$cfg_note" ] && cfg_note=""

    $first || echo ','
    first=false
    printf '{"section":"%s","interface":"%s","usb_port":"%s","mac":"%s","ip":"%s","alias":"%s","target_ip":"%s","note":"%s"}' \
        "$cfg_section" "$name" "$usb_port" "$mac" "${ip:-}" "$cfg_alias" "$cfg_ip" "$cfg_note"
done
echo ']}'
