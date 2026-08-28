#!/usr/bin/env bash
# make-seed.sh - aus einer user-data ein NoCloud-Seed-ISO fuer die
# Display-VMs bauen.
#
#   ./make-user-data.sh --hostname display-a --kiosk
#   ./make-seed.sh --hostname display-a
#   -> display-a-seed.iso, in Hyper-V als zweites Laufwerk anhaengen
#
# Der Raspberry Pi braucht das ISO nicht: Ubuntus Pi-Images lesen cloud-init
# direkt aus der Boot-Partition. Dort wird dieselbe user-data einfach als
# Datei abgelegt - gleicher Inhalt, anderer Transportweg. Genau das ist der
# Grund, ueberhaupt cloud-init zu nehmen statt eines eigenen Erstboot-Skripts.
#
# Warum "cidata" als Datentraegername: cloud-init sucht den NoCloud-Datentraeger
# genau unter diesem Label. Ein anderer Name und die VM bootet ohne
# Konfiguration - stumm, ohne Fehlermeldung.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOSTNAME_ARG="raumfrei-display"
USER_DATA="${HERE}/user-data"
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname)  HOSTNAME_ARG="$2"; shift 2 ;;
        --user-data) USER_DATA="$2";    shift 2 ;;
        --out)       OUT="$2";          shift 2 ;;
        -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

OUT="${OUT:-${HERE}/${HOSTNAME_ARG}-seed.iso}"

if [ ! -r "$USER_DATA" ]; then
    echo "FEHLER: ${USER_DATA} fehlt - zuerst make-user-data.sh ausfuehren." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$USER_DATA" "${WORK}/user-data"

# Die instance-id entscheidet, ob cloud-init den Erstboot wiederholt. Fuer
# geklonte VMs muss sie sich unterscheiden, sonst haelt die zweite VM sich fuer
# die erste und laesst die Konfiguration ganz aus.
cat > "${WORK}/meta-data" <<META
instance-id: ${HOSTNAME_ARG}-$(date +%s)
local-hostname: ${HOSTNAME_ARG}
META

if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$OUT" "${WORK}/user-data" "${WORK}/meta-data"
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "$OUT" -volid cidata -joliet -rock \
        "${WORK}/user-data" "${WORK}/meta-data" >/dev/null 2>&1
elif command -v xorrisofs >/dev/null 2>&1; then
    xorrisofs -output "$OUT" -volid cidata -joliet -rock \
        "${WORK}/user-data" "${WORK}/meta-data" >/dev/null 2>&1
else
    echo "FEHLER: weder cloud-localds noch genisoimage noch xorrisofs gefunden." >&2
    echo "        sudo apt install cloud-image-utils genisoimage" >&2
    exit 1
fi

chmod 600 "$OUT"
echo "Seed-ISO geschrieben: $OUT  ($(wc -c < "$OUT") Bytes)"
echo
echo "Hyper-V: Gen 2, Secure Boot AUS, das ISO als zweites Laufwerk anhaengen,"
echo "         als Systemplatte eine differencing disk vom Golden-VHDX."
echo "Pi:      user-data stattdessen direkt in die Partition system-boot legen."
