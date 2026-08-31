#!/usr/bin/env bash
# push_probe.sh - Messreihe M7: die Push-Gegenprobe.
#
# Laeuft auf der ZENTRALEN Seite (WSL, Incus-Host, irgendein Linux mit
# ansible), nicht auf dem Tuerschild:
#
#     bash push_probe.sh
#
# Die These lautet: eine Steuerung, die Konfiguration zu den Geraeten
# schiebt, funktioniert in diesem Aufbau nicht - nicht weil sie schlecht
# waere, sondern weil es keinen Weg dorthin gibt. Das ist eine Behauptung,
# solange sie niemand probiert hat. Also wird sie probiert.
#
# Ablauf:
#   1. Das Backend nach den Geraeten fragen (GET /devices). Nur dort stehen
#      ueberhaupt Adressen - und zwar die, die die Geraete selbst gemeldet
#      haben. Ein Inventar im klassischen Sinn gibt es nicht.
#   2. Aus diesen Adressen ein Ansible-Inventar bauen.
#   3. ansible -m ping dagegen laufen lassen.
#   4. Zusaetzlich roh auf Port 22 klopfen.
#
# Erwartet: UNREACHABLE. Und der Grund steht schon in Schritt 1 - die
# gemeldeten Adressen sind privat. Sie sind vom Backend aus nicht einmal
# adressierbar.
#
# EHRLICHKEIT ZUR AUSSAGEKRAFT: Wird dieses Skript im selben Netz wie die
# Geraete ausgefuehrt, kann der Ping durchaus gelingen - dann misst es die
# Erreichbarkeit im LAN, nicht die von der Steuerungsebene aus. Das Skript
# prueft das und schreibt es dazu. Der belastbare Fall ist der Blick von
# aussen: das Backend ist eine Lambda-Funktion in eu-central-1 und hat auf
# 192.168.x.x keinen Weg.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
RESULTS="${HERE}/results"
BERICHT="${RESULTS}/push_probe.txt"
SECRETS="${REPO}/backend/secrets.env"

while [ $# -gt 0 ]; do
    case "$1" in
        --secrets) SECRETS="$2"; shift 2 ;;
        --bericht) BERICHT="$2"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

if [ -r "$SECRETS" ]; then
    # shellcheck disable=SC1090
    set -a; . "$SECRETS"; set +a
fi
: "${BACKEND_URL:?BACKEND_URL fehlt - secrets.env angeben oder Variable setzen}"
: "${ADMIN_KEY:?ADMIN_KEY fehlt - secrets.env angeben oder Variable setzen}"

mkdir -p "$RESULTS"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
exec > >(tee "$BERICHT") 2>&1

echo "=============================================================="
echo "M7 - PUSH-GEGENPROBE     $(date -Is)"
echo "ausgefuehrt auf: $(hostname)   Adresse: $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "=============================================================="

# --- 1 Was weiss die zentrale Seite ueberhaupt? ------------------------------
echo
echo "--- 1 Geraete laut Backend --------------------------------------"
DEVICES="${WORK}/devices.json"
if ! curl -fsS --max-time 20 "${BACKEND_URL}/devices" -H "X-Admin-Key: ${ADMIN_KEY}" -o "$DEVICES"; then
    echo "FEHLER: GET /devices nicht erreichbar. Ohne Geraeteliste keine Probe."
    exit 1
fi

python3 - "$DEVICES" <<'PYTHON'
import json, sys
d = json.load(open(sys.argv[1]))
items = d.get("devices", d if isinstance(d, list) else [])
print("  %-14s %-16s %-10s %s" % ("deviceId", "gemeldete IP", "Status", "Raum"))
for it in items:
    print("  %-14s %-16s %-10s %s" % (
        it.get("deviceId", "-"), it.get("lastReport", {}).get("ip") or it.get("ip") or "-",
        it.get("status", "-"), it.get("roomId") or "-"))
print()
print("  Diese Adressen hat kein Administrator gepflegt - sie stammen aus den")
print("  Check-ins der Geraete selbst. Ein Inventar, das jemand aktuell halten")
print("  muesste, gibt es in diesem Aufbau nicht.")
PYTHON

# IPs herausziehen
IPS="$(python3 - "$DEVICES" <<'PYTHON'
import json, sys
d = json.load(open(sys.argv[1]))
items = d.get("devices", d if isinstance(d, list) else [])
for it in items:
    ip = (it.get("lastReport") or {}).get("ip") or it.get("ip")
    if ip:
        print(ip)
PYTHON
)"

if [ -z "$IPS" ]; then
    echo
    echo "Keine Adressen gemeldet - noch kein Check-in erfolgt. Erst ein Geraet"
    echo "laufen lassen, dann diese Probe wiederholen."
    exit 1
fi

# --- Aussagekraft pruefen ----------------------------------------------------
MEIN_NETZ="$(hostname -I 2>/dev/null | awk '{print $1}' | cut -d. -f1-3)"
GLEICHES_NETZ=0
for ip in $IPS; do
    [ "$(printf '%s' "$ip" | cut -d. -f1-3)" = "$MEIN_NETZ" ] && GLEICHES_NETZ=1
done

echo
echo "--- 2 Ansible-Inventar aus diesen Adressen ----------------------"
INV="${WORK}/inventory"
{
    echo "[displays]"
    for ip in $IPS; do echo "$ip"; done
    echo
    echo "[displays:vars]"
    echo "ansible_user=root"
    echo "ansible_connection=ssh"
} > "$INV"
sed 's/^/  /' "$INV"
cp "$INV" "${RESULTS}/push_probe_inventory.txt"

echo
echo "--- 3 ansible -m ping -------------------------------------------"
if command -v ansible >/dev/null 2>&1; then
    ANSIBLE_HOST_KEY_CHECKING=False timeout 90 \
        ansible -i "$INV" all -m ping \
        -e ansible_ssh_common_args='-o ConnectTimeout=5 -o BatchMode=yes' 2>&1 | sed 's/^/  /'
    echo
    echo "  (Rueckgabe ungleich 0 ist hier das erwartete Ergebnis.)"
else
    echo "  ansible ist auf dieser Maschine nicht installiert."
    echo "  Ersatzweise wird nur roh auf Port 22 geklopft - siehe Schritt 4."
fi

echo
echo "--- 4 Rohe TCP-Probe auf Port 22 --------------------------------"
for ip in $IPS; do
    if timeout 5 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null; then
        echo "  ${ip}:22  offen"
    else
        echo "  ${ip}:22  keine Verbindung"
    fi
done

echo
echo "=============================================================="
echo "EINORDNUNG"
echo "=============================================================="
if [ "$GLEICHES_NETZ" -eq 1 ]; then
    echo "Diese Probe lief im SELBEN Netz wie die Geraete (${MEIN_NETZ}.0/24)."
    echo "Was hier gelingt, gelingt einem Steuerungsserver ausserhalb trotzdem"
    echo "nicht: die Adressen sind privat und hinter NAT nicht adressierbar."
    echo "Fuer den Bericht ist der Befund aus Schritt 1 der tragende - dass die"
    echo "einzige bekannte Adresse eine private ist, die das Geraet selbst"
    echo "gemeldet hat."
else
    echo "Diese Probe lief AUSSERHALB des Geraetenetzes. Das Ergebnis oben ist"
    echo "damit der direkte Beleg: von der zentralen Seite fuehrt kein Weg zum"
    echo "Geraet. Push ist in diesem Aufbau nicht moeglich - Pull ist keine"
    echo "Vorliebe, sondern die einzige Bauweise, die funktioniert."
fi
echo
echo "geschrieben: ${BERICHT}"
