#!/usr/bin/env bash

modem_usb_parent() {
    local tty_name=${1##*/}
    local path
    path=$(readlink -f "${SIM_DECK_SYS_CLASS_TTY:-/sys/class/tty}/$tty_name/device") || return 1
    while [[ "$path" != "/" ]]; do
        if [[ -f "$path/idVendor" && -f "$path/idProduct" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
        path=${path%/*}
        [[ -n "$path" ]] || path=/
    done
    return 1
}

ports_share_modem() {
    local first second
    first=$(modem_usb_parent "$1") || return 1
    second=$(modem_usb_parent "$2") || return 1
    [[ "$first" == "$second" ]]
}

wifi_calling_enabled() {
    local policy=${1:-/var/lib/sim-deck/slot-policy.json}
    local setting
    # The device serializes active settings before inactive eSIM profiles.
    setting=$(grep -Eo '"wifi_calling_enabled":[[:space:]]*(true|false)' "$policy" 2>/dev/null | head -n 1 || true)
    [[ "$setting" == *true ]]
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

set -euo pipefail

config=/run/sim-deck-vowifi/config.toml
generation=/var/lib/sim-deck/ims-profile-generation

if [[ ! -c "${SIM_DECK_IMS_AT_DEVICE:-}" || ! -c "${SIM_DECK_DEVICE_AT_DEVICE:-}" ]]; then
    echo "VoWiFi requires two existing modem AT character devices" >&2
    exit 1
fi
ims_at=$(readlink -f "$SIM_DECK_IMS_AT_DEVICE")
device_at=$(readlink -f "$SIM_DECK_DEVICE_AT_DEVICE")
if [[ "$ims_at" == "$device_at" ]]; then
    echo "VoWiFi companion and SimDeck cannot open the same AT port" >&2
    exit 1
fi
if [[ ! "$ims_at" =~ ^/dev/ttyUSB[0-9]+$ || ! "$device_at" =~ ^/dev/ttyUSB[0-9]+$ ]]; then
    echo "VoWiFi AT ports must resolve to /dev/ttyUSB devices" >&2
    exit 1
fi
if ! ports_share_modem "$ims_at" "$device_at"; then
    echo "VoWiFi AT ports must belong to the same USB modem" >&2
    exit 1
fi
if [[ -z "${SIM_DECK_VOWIFI_SIP_PASSWORD:-}" ]]; then
    echo "SIM_DECK_VOWIFI_SIP_PASSWORD is required" >&2
    exit 1
fi

excluded=()
for port in /dev/ttyUSB*; do
    [[ -c "$port" && "$port" != "$ims_at" ]] || continue
    excluded+=("\"$port\"")
done
exclusions=$(IFS=,; echo "${excluded[*]}")
mkdir -p "$(dirname "$config")"
cat > "$config" <<EOF
[sip]
local_port = 5062

[sip_server]
enabled = true
listen_addr = "127.0.0.1"
listen_port = 5060
ring_aor = "simdeck"

[[sip_server.account]]
username = "simdeck"
password = "env:SIM_DECK_VOWIFI_SIP_PASSWORD"

[outbound]
enabled = true

[cs]
enabled = false

[sms]
enabled = false

[vowifi]
enabled = true
max_lines = 1

[[vowifi.line]]
modem_port = "$ims_at"

[discovery]
excluded_ports = [$exclusions]

[metrics]
port = 9091

[webui]
enabled = false
EOF
chmod 0600 "$config"

if [[ "${1:-}" == "--validate" ]]; then
    exec /usr/local/bin/gsm-sip-bridge --config "$config" config vowifi-enabled
fi

child=0
watcher=0
stop() {
    if (( watcher > 0 )); then kill "$watcher" 2>/dev/null || true; fi
    if (( child > 0 )); then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    exit 0
}
trap stop TERM INT

while true; do
    if ! wifi_calling_enabled; then
        sleep 1
        continue
    fi
    before=$(cat "$generation" 2>/dev/null || true)
    /usr/local/bin/gsm-sip-bridge --config "$config" supervise &
    child=$!
    (
        while sleep 1; do
            now=$(cat "$generation" 2>/dev/null || true)
            if [[ "$now" != "$before" ]] || ! wifi_calling_enabled; then
                kill -TERM "$child" 2>/dev/null || true
                break
            fi
        done
    ) &
    watcher=$!
    wait "$child" || true
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    child=0
    watcher=0
    sleep 5
done
