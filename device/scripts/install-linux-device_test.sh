#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-linux-device.sh
source "$script_dir/install-linux-device.sh"

fixture="$(mktemp -d)"
mkdir -p "$fixture/bin" "$fixture/dev/snd"
touch "$fixture/dev/snd/controlC2" "$fixture/dev/snd/pcmC2D0c" "$fixture/dev/snd/pcmC2D0p"
touch "$fixture/dev/snd/controlC3" "$fixture/dev/snd/pcmC3D0c" "$fixture/dev/snd/pcmC3D0p"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  *controlC2*) printf "%s\n" "ID_VENDOR_ID=2c7c" "ID_SERIAL_SHORT=0123456789ABCDEF" "ID_PATH=pci-test-usb-0:1:0.0" ;;' \
  '  *ttyUSB2*) printf "%s\n" "ID_VENDOR_ID=2c7c" "ID_SERIAL_SHORT=0123456789ABCDEF" "ID_USB_INTERFACE_NUM=02" "ID_PATH=pci-test-usb-0:1:1.2" ;;' \
  '  *controlC3*) printf "%s\n" "ID_VENDOR_ID=2c7c" "ID_SERIAL_SHORT=0123456789ABCDEF" "ID_PATH=pci-test-usb-0:2:0.0" ;;' \
  '  *ttyUSB3*) printf "%s\n" "ID_VENDOR_ID=2c7c" "ID_SERIAL_SHORT=0123456789ABCDEF" "ID_USB_INTERFACE_NUM=02" "ID_PATH=pci-test-usb-0:2:1.2" ;;' \
  'esac' \
  > "$fixture/bin/udevadm"
chmod +x "$fixture/bin/udevadm"
PATH="$fixture/bin:$PATH"

declare -A audio_control=() audio_capture=() audio_playback=()
discover_audio_nodes "$fixture/dev"
[[ "${audio_control[0123456789ABCDEF|pci-test-usb-0:1]}" == "$fixture/dev/snd/controlC2" ]]
[[ "${audio_capture[0123456789ABCDEF|pci-test-usb-0:1]}" == "$fixture/dev/snd/pcmC2D0c" ]]
[[ "${audio_playback[0123456789ABCDEF|pci-test-usb-0:1]}" == "$fixture/dev/snd/pcmC2D0p" ]]
[[ "${audio_control[0123456789ABCDEF|pci-test-usb-0:2]}" == "$fixture/dev/snd/controlC3" ]]

rule="$(write_tty_rule 0123456789ABCDEF 02 1 pci-test-usb-0:1)"
grep -Fq 'ENV{ID_MM_DEVICE_IGNORE}="1"' <<< "$rule"
grep -Fq 'ENV{ID_USB_INTERFACE_NUM}=="02"' <<< "$rule"
grep -Fq 'ENV{ID_PATH}=="pci-test-usb-0:1*"' <<< "$rule"
grep -Fq 'SYMLINK+="sim-deck/modem-1-at"' <<< "$rule"
audio_rule="$(write_audio_rule 'controlC*' 0123456789ABCDEF pci-test-usb-0:1 1 control)"
grep -Fq 'ENV{ID_PATH}=="pci-test-usb-0:1*"' <<< "$audio_rule"

touch "$fixture/dev/ttyUSB2" "$fixture/dev/ttyUSB3"
inventory="$(SIM_DECK_DEV_ROOT="$fixture/dev" main)"
grep -Fq 'Discovered 2 modem(s). No files were changed.' <<< "$inventory"
grep -Fq "│   ├── host: $fixture/dev/ttyUSB2" <<< "$inventory"
grep -Fq "│   ├── host: $fixture/dev/ttyUSB3" <<< "$inventory"
grep -Fq "│   ├── capture: $fixture/dev/snd/pcmC2D0c" <<< "$inventory"

printf '%s\n' 'install-linux-device tests passed'
