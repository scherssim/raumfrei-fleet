#!/usr/bin/env bash
# fleet_up.sh - die Flotte im Kleinen: Messreihen M6 (Skalierung) und
# M2 (zentrale Wirkung).
#
# Laeuft auf dem Incus-Host (Linux), nicht auf einem Tuerschild:
#
#     bash fleet_up.sh up --anzahl 20        # 20 headless Agents starten
#     bash fleet_up.sh status                # was laeuft, was hat gemeldet
#     bash fleet_up.sh konvergenz --minuten 60
#     bash fleet_up.sh down                  # alles wieder weg
#
# Warum Container und nicht 20 VMs: gemessen wird der Aufwand PRO GERAET,
# nicht die Leistung eines Hypervisors. Ein Agent-Container fuehrt dieselbe
# Kette aus wie ein Tuerschild - Enrollment, Pull, Check-in - nur ohne
# Bildschirm. Genau deshalb steht die Kiosk-Zugehoerigkeit im Image
# (/etc/raumfrei/kiosk.enabled) und nicht im Backend: diese zwanzig
# Container sollen weder cage noch einen Browser installieren, sonst misst
# man das Herunterladen eines Browsers und nennt es Skalierung.
#
# STOLPERSTEIN, der Zeit gekostet hat: die deviceId wird aus der MAC
# abgeleitet. Zwei Container mit derselben MAC waeren fuer das Backend
# dasselbe Geraet - die Flotte haette dann eine Groesse von eins. Incus
# vergibt je Instanz eine eigene MAC; das Skript prueft es trotzdem nach,
# weil der Fehler sonst erst in der Auswertung auffiele.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
RESULTS="${HERE}/results"
SECRETS="${REPO}/backend/secrets.env"

PRAEFIX="agent"
ANZAHL=20
IMAGE="images:ubuntu/24.04/cloud"
USER_DATA="${REPO}/client/cloud-init/user-data"
MINUTEN=60

BEFEHL="${1:-help}"; shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --anzahl)  ANZAHL="$2";   shift 2 ;;
        --praefix) PRAEFIX="$2";  shift 2 ;;
        --image)   IMAGE="$2";    shift 2 ;;
        --user-data) USER_DATA="$2"; shift 2 ;;
        --minuten) MINUTEN="$2";  shift 2 ;;
        --secrets) SECRETS="$2";  shift 2 ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

command -v incus >/dev/null 2>&1 || { echo "FEHLER: incus fehlt. (apt install incus; incus admin init --minimal)" >&2; exit 1; }
mkdir -p "$RESULTS"

name_von() { printf "%s-%02d" "$PRAEFIX" "$1"; }
jetzt() { date +%s; }

# ---------------------------------------------------------------------- up
befehl_up() {
    if [ ! -r "$USER_DATA" ]; then
        echo "FEHLER: ${USER_DATA} fehlt." >&2
        echo "  zuerst:  bash client/cloud-init/make-user-data.sh --hostname agent --headless" >&2
        exit 1
    fi
    if grep -q "kiosk.enabled" "$USER_DATA"; then
        echo "WARNUNG: diese user-data setzt den Kiosk-Marker. Fuer die Agents" >&2
        echo "         die --headless-Variante nehmen, sonst zieht jeder"       >&2
        echo "         Container cage und einen Browser."                        >&2
    fi

    echo "=============================================================="
    echo "M6 - ${ANZAHL} Agents starten     $(date -Is)"
    echo "=============================================================="
    echo "Handgriffe pro Geraet: 0 (nach dem Start greift niemand mehr ein)"
    echo

    local start ende dauer name
    start="$(jetzt)"
    for i in $(seq 1 "$ANZAHL"); do
        name="$(name_von "$i")"
        if incus info "$name" >/dev/null 2>&1; then
            echo "  ${name}: existiert schon, uebersprungen"
            continue
        fi
        incus launch "$IMAGE" "$name" \
            -c cloud-init.user-data="$(cat "$USER_DATA")" \
            >/dev/null 2>&1 \
            && echo "  ${name}: gestartet" \
            || echo "  ${name}: FEHLGESCHLAGEN"
    done
    ende="$(jetzt)"
    dauer=$(( ende - start ))

    echo
    echo "${ANZAHL} Container gestartet in ${dauer} s (${PRAEFIX})."

    # MACs pruefen - siehe Kopf des Skripts.
    echo
    echo "MAC-Adressen (muessen alle verschieden sein):"
    local macs
    macs="$(for i in $(seq 1 "$ANZAHL"); do
                incus config get "$(name_von "$i")" volatile.eth0.hwaddr 2>/dev/null
            done | grep -v '^$')"
    local anzahl_macs anzahl_eindeutig
    anzahl_macs="$(printf '%s\n' "$macs" | wc -l)"
    anzahl_eindeutig="$(printf '%s\n' "$macs" | sort -u | wc -l)"
    echo "  ${anzahl_macs} Adressen, ${anzahl_eindeutig} davon eindeutig"
    if [ "$anzahl_macs" != "$anzahl_eindeutig" ]; then
        echo "  FEHLER: doppelte MAC - die betroffenen Container werden vom"
        echo "          Backend als EIN Geraet gefuehrt. Messung ungueltig."
    fi

    [ -s "${RESULTS}/scale.csv" ] || \
        echo "aktion;anzahl;dauer_s;handgriffe_pro_geraet;gemessen_am" > "${RESULTS}/scale.csv"
    echo "start;${ANZAHL};${dauer};0;$(date -Is)" >> "${RESULTS}/scale.csv"
    echo
    echo "angehaengt an ${RESULTS}/scale.csv"
    echo
    echo "Fuer M6 den Vergleich fahren: erst 'down', dann"
    echo "  bash fleet_up.sh up --anzahl 2    und   bash fleet_up.sh up --anzahl 10"
    echo "Die Aussage ist nicht die Sekundenzahl, sondern dass die Handgriffe"
    echo "je Geraet bei null bleiben - unabhaengig von der Stueckzahl."
}

# ------------------------------------------------------------------ status
befehl_status() {
    echo "--- Container ---------------------------------------------------"
    incus list "^${PRAEFIX}-" -c ns4 2>/dev/null
    echo
    echo "--- Was das Backend sieht ---------------------------------------"
    if [ -r "$SECRETS" ]; then
        # shellcheck disable=SC1090
        set -a; . "$SECRETS"; set +a
    fi
    if [ -z "${BACKEND_URL:-}" ] || [ -z "${ADMIN_KEY:-}" ]; then
        echo "  (BACKEND_URL/ADMIN_KEY unbekannt - secrets.env angeben)"
        return
    fi
    curl -fsS --max-time 20 "${BACKEND_URL}/devices" -H "X-Admin-Key: ${ADMIN_KEY}" \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
items = d.get("devices", d if isinstance(d, list) else [])
zaehler = {}
for it in items:
    zaehler[it.get("compliance", "-")] = zaehler.get(it.get("compliance", "-"), 0) + 1
print("  %d Geraete gemeldet" % len(items))
for k, v in sorted(zaehler.items()):
    print("    %-16s %d" % (k, v))
'
}

# -------------------------------------------------------------- konvergenz
befehl_konvergenz() {
    # M2: von der zentralen Aenderung bis zum Check-in jedes Geraets.
    #
    # Der Nullpunkt ist bewusst die Zeit des Commits bzw. der Zuweisung -
    # nicht der Start dieses Skripts. Gemessen wird, was ein Betreiber
    # erlebt: "ich habe etwas geaendert, wann ist es ueberall angekommen?"
    if [ -r "$SECRETS" ]; then
        # shellcheck disable=SC1090
        set -a; . "$SECRETS"; set +a
    fi
    : "${BACKEND_URL:?BACKEND_URL fehlt}"; : "${ADMIN_KEY:?ADMIN_KEY fehlt}"

    local csv="${RESULTS}/convergence.csv"
    [ -s "$csv" ] || echo "deviceId;soll_version;ist_version;sekunden_seit_aenderung;compliance;gemessen_am" > "$csv"

    local t0 grenze
    t0="$(jetzt)"
    grenze=$(( MINUTEN * 60 ))

    echo "=============================================================="
    echo "M2 - Konvergenz messen     Start $(date -Is)"
    echo "=============================================================="
    echo "Nullpunkt ist JETZT. Die zentrale Aenderung (Commit oder assign)"
    echo "muss unmittelbar vorher passiert sein, sonst misst die Reihe"
    echo "eine falsche Wartezeit."
    echo "Beobachtungsfenster: ${MINUTEN} Minuten. Abbruch mit Strg-C."
    echo

    local gesehen="${RESULTS}/.konvergenz_gesehen"
    : > "$gesehen"

    while [ $(( $(jetzt) - t0 )) -lt "$grenze" ]; do
        curl -fsS --max-time 20 "${BACKEND_URL}/devices" -H "X-Admin-Key: ${ADMIN_KEY}" 2>/dev/null \
        | python3 - "$t0" "$csv" "$gesehen" <<'PYTHON'
import json, sys, time, os
t0, csv_pfad, gesehen_pfad = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
items = d.get("devices", d if isinstance(d, list) else [])
gesehen = set(open(gesehen_pfad).read().split()) if os.path.exists(gesehen_pfad) else set()
neu = []
for it in items:
    dev = it.get("deviceId", "-")
    soll = it.get("configVersion") or it.get("desiredConfigVersion") or ""
    ist = it.get("reportedConfigVersion") or ""
    if dev in gesehen or not soll or ist != soll:
        continue
    sek = int(time.time()) - t0
    neu.append(dev)
    with open(csv_pfad, "a") as f:
        f.write("%s;%s;%s;%d;%s;%s\n" % (
            dev, soll, ist, sek, it.get("compliance", "-"),
            time.strftime("%Y-%m-%dT%H:%M:%S%z")))
    print("  %s  angekommen nach %d s  (%s)" % (dev, sek, it.get("compliance", "-")))
if neu:
    with open(gesehen_pfad, "a") as f:
        f.write("\n".join(neu) + "\n")
PYTHON
        sleep 15
    done

    echo
    echo "Fenster zu Ende. Ergebnis in ${csv}"
    echo "Nicht angekommene Geraete sind ebenfalls ein Befund - sie stehen"
    echo "nicht in der CSV und gehoeren als solche in die Auswertung."
}

# -------------------------------------------------------------------- down
befehl_down() {
    echo "Loesche Container mit Praefix '${PRAEFIX}-' ..."
    local liste
    liste="$(incus list "^${PRAEFIX}-" -c n --format csv 2>/dev/null)"
    if [ -z "$liste" ]; then echo "  nichts zu tun."; return; fi
    echo "$liste" | sed 's/^/  /'
    for name in $liste; do
        incus delete --force "$name" >/dev/null 2>&1 && echo "  ${name}: geloescht"
    done
    echo
    echo "Hinweis: die Geraete stehen weiterhin im Backend. Fuer einen sauberen"
    echo "Neustart der Messreihe ueber fleet.html ausmustern (retire) - das ist"
    echo "genau der Lebenszyklus-Schritt, den ein geloeschter Container sonst"
    echo "offen laesst."
}

case "$BEFEHL" in
    up)         befehl_up ;;
    status)     befehl_status ;;
    konvergenz) befehl_konvergenz ;;
    down)       befehl_down ;;
    *) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
