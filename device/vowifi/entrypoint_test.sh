#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/entrypoint.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export SIM_DECK_SYS_CLASS_TTY="$fixture/class/tty"

mkdir -p "$fixture/devices/usb1/1-1/1-1:1.0/ttyUSB1"
mkdir -p "$fixture/devices/usb1/1-1/1-1:1.1/ttyUSB2"
mkdir -p "$fixture/devices/usb1/1-2/1-2:1.0/ttyUSB3"
touch "$fixture/devices/usb1/1-1/idVendor" "$fixture/devices/usb1/1-1/idProduct"
touch "$fixture/devices/usb1/1-2/idVendor" "$fixture/devices/usb1/1-2/idProduct"

for port in 1 2 3; do
    mkdir -p "$SIM_DECK_SYS_CLASS_TTY/ttyUSB$port"
done
ln -s "$fixture/devices/usb1/1-1/1-1:1.0/ttyUSB1" "$SIM_DECK_SYS_CLASS_TTY/ttyUSB1/device"
ln -s "$fixture/devices/usb1/1-1/1-1:1.1/ttyUSB2" "$SIM_DECK_SYS_CLASS_TTY/ttyUSB2/device"
ln -s "$fixture/devices/usb1/1-2/1-2:1.0/ttyUSB3" "$SIM_DECK_SYS_CLASS_TTY/ttyUSB3/device"

ports_share_modem /dev/ttyUSB1 /dev/ttyUSB2
if ports_share_modem /dev/ttyUSB1 /dev/ttyUSB3; then
    echo "accepted AT ports from different modems" >&2
    exit 1
fi
if ports_share_modem /dev/ttyUSB1 /dev/ttyUSB4; then
    echo "accepted a missing AT port" >&2
    exit 1
fi

policy="$fixture/slot-policy.json"
if wifi_calling_enabled "$policy"; then
    echo "enabled IMS without a saved Wi-Fi Calling preference" >&2
    exit 1
fi
printf '%s\n' '{"version":2,"wifi_calling_enabled":false,"profiles":{"inactive":{"wifi_calling_enabled":true}}}' > "$policy"
if wifi_calling_enabled "$policy"; then
    echo "enabled IMS from an inactive eSIM profile" >&2
    exit 1
fi
printf '%s\n' '{"version":2,"wifi_calling_enabled":true,"profiles":{"inactive":{"wifi_calling_enabled":false}}}' > "$policy"
if ! wifi_calling_enabled "$policy"; then
    echo "ignored the active Wi-Fi Calling preference" >&2
    exit 1
fi

echo "VoWiFi AT port ownership and preference checks passed"
