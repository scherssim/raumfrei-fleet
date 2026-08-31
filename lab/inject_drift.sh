#!/usr/bin/env bash
# inject_drift.sh - Messreihe M4: die Drift-Matrix.
#
# Laeuft AUF dem Tuerschild als root:
#
#     sudo bash inject_drift.sh --fall alle
#     sudo bash inject_drift.sh --fall url
#
# Vier Faelle, in denen jemand am Geraet etwas verstellt. Gemessen wird je
# Fall dreierlei:
#
#   1. Heilt es die LOKALE Schicht?   systemd Restart=always, Sekunden
#   2. Heilt es die ZENTRALE Schicht? der naechste ansible-pull
#   3. Wird es GEMELDET?              compliance im Check-in
#
# Die Zweiteilung ist der Kern der Aussage: ein abgestuerzter Browser ist in
# Sekunden zurueck, eine verstellte Konfiguration lebt bis zum naechsten
# Pull. Beides ist gewollt - aber nur, wenn man es auseinanderhaelt.
#
# WICHTIG fuer die Auswertung: die zentrale Heilung wird hier durch einen
# sofortigen Agent-Lauf ausgeloest, damit die Messung nicht 50 Minuten
# dauert. Die echte Latenz im Betrieb ist der Abstand zum naechsten
# Lektionsende; das Skript schreibt ihn als "naechster_timer" mit, damit im
# Bericht beides steht: die Dauer der Korrektur und die Wartezeit darauf.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS="${HERE}/results"
CSV="${RESULTS}/drift.csv"
FALL="alle"
LOKAL_FENSTER=45      # Sekunden, die auf die lokale Heilung gewartet wird

while [ $# -gt 0 ]; do
    case "$1" in
        --fall)    FALL="$2";  shift 2 ;;
        --csv)     CSV="$2";   shift 2 ;;
        --fenster) LOKAL_FENSTER="$2"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "FEHLER: als root ausfuehren." >&2; exit 1; }
[ -r /etc/raumfrei/kiosk.env ] || { echo "FEHLER: /etc/raumfrei/kiosk.env fehlt - kein Tuerschild?" >&2; exit 1; }

# shellcheck disable=SC1091
. /etc/raumfrei/kiosk.env
BROWSER_PAKET="${KIOSK_BROWSER:-cog}"
case "$BROWSER_PAKET" in
    chromium) BROWSER_PAKET="chromium-browser" ;;
esac
SOLL_URL="$KIOSK_URL"

mkdir -p "$RESULTS"
[ -s "$CSV" ] || echo "fall;was_verstellt;heilende_schicht;lokal_geheilt_s;pull_dauer_s;ansible_changed;compliance;naechster_timer;gemessen_am" > "$CSV"

jetzt() { date +%s; }
uhr()   { date +%H:%M:%S; }

# --- Pruefungen: ist der Soll-Zustand wiederhergestellt? ---------------------
pruef_kiosk()     { systemctl is-active --quiet raumfrei-kiosk.service; }
pruef_url()       { grep -q "^KIOSK_URL=${SOLL_URL}$" /etc/raumfrei/kiosk.env; }
pruef_paket()     { dpkg -s "$BROWSER_PAKET" >/dev/null 2>&1; }
pruef_autostart() { [ "$(systemctl is-enabled raumfrei-kiosk.service 2>/dev/null)" = "enabled" ]; }

warte_auf_heilung() {
    # warte_auf_heilung <pruef-funktion> <sekunden> -> Sekunden bis geheilt, "" wenn nicht
    local pruef="$1" grenze="$2" start
    start="$(jetzt)"
    while [ $(( $(jetzt) - start )) -lt "$grenze" ]; do
        if "$pruef"; then echo $(( $(jetzt) - start )); return 0; fi
        sleep 1
    done
    echo ""
    return 1
}

naechster_timer() {
    systemctl list-timers raumfrei-agent.timer --no-pager --no-legend 2>/dev/null \
        | awk '{print $1, $2, $3}' | head -1
    # leer, wenn der Timer nicht laeuft - auch das ist ein Befund
}

# --- Zentrale Schicht: einen Agent-Lauf ausloesen ---------------------------
zentral_heilen() {
    local start ende
    start="$(jetzt)"
    systemctl start raumfrei-agent.service >/dev/null 2>&1
    ende="$(jetzt)"
    PULL_DAUER=$(( ende - start ))

    # Recap des Laufs: wie viele Tasks hat Ansible korrigiert?
    ANSIBLE_CHANGED="$(grep -E '^localhost\s+:' /var/lib/raumfrei/last-pull.log 2>/dev/null \
        | tail -1 | sed -n 's/.*changed=\([0-9]\+\).*/\1/p')"
    ANSIBLE_CHANGED="${ANSIBLE_CHANGED:-?}"

    # Was hat das Backend daraus gemacht? Der Agent protokolliert die Antwort.
    COMPLIANCE="$(journalctl -u raumfrei-agent.service --no-pager -n 40 2>/dev/null \
        | grep -o 'Check-in: [A-Z_]*' | tail -1 | awk '{print $2}')"
    COMPLIANCE="${COMPLIANCE:-?}"
}

# --- Ein Fall ----------------------------------------------------------------
fall_ausfuehren() {
    local name="$1" beschreibung="$2" injizieren="$3" pruef="$4" erwartet="$5"

    echo
    echo "=============================================================="
    echo "FALL ${name} - ${beschreibung}"
    echo "erwartete heilende Schicht: ${erwartet}"
    echo "=============================================================="

    if ! "$pruef"; then
        echo "ABBRUCH: der Soll-Zustand steht schon vor dem Eingriff nicht."
        echo "         Zuerst 'systemctl start raumfrei-agent.service' laufen lassen."
        return 1
    fi

    local timer_vorher
    timer_vorher="$(naechster_timer)"

    echo "$(uhr)  Eingriff ..."
    "$injizieren"
    sleep 2
    if "$pruef"; then
        echo "         WARNUNG: der Eingriff hat nichts veraendert - Fall nicht aussagekraeftig."
    fi

    echo "$(uhr)  warte bis zu ${LOKAL_FENSTER} s auf die lokale Schicht ..."
    LOKAL="$(warte_auf_heilung "$pruef" "$LOKAL_FENSTER")"

    if [ -n "$LOKAL" ]; then
        echo "$(uhr)  lokal geheilt nach ${LOKAL} s (systemd)."
        SCHICHT="lokal"
        PULL_DAUER=""; ANSIBLE_CHANGED=""; COMPLIANCE=""
        # Trotzdem einen Pull fahren: die Meldung an das Backend gehoert dazu,
        # sonst steht in der Flotte nichts von diesem Vorfall.
        zentral_heilen
    else
        echo "$(uhr)  nach ${LOKAL_FENSTER} s nicht lokal geheilt - erwartet."
        echo "$(uhr)  loese den zentralen Lauf aus (im Betrieb: naechstes Lektionsende) ..."
        zentral_heilen
        if "$pruef"; then
            echo "$(uhr)  zentral geheilt, Pull dauerte ${PULL_DAUER} s (changed=${ANSIBLE_CHANGED})."
            SCHICHT="zentral"
        else
            echo "$(uhr)  NICHT geheilt - auch der Pull hat es nicht korrigiert."
            SCHICHT="keine"
        fi
    fi

    echo "         Check-in meldete: ${COMPLIANCE:-?}"
    echo "         naechster regulaerer Lauf waere: ${timer_vorher:-Timer laeuft nicht}"

    echo "${name};${beschreibung};${SCHICHT};${LOKAL:-};${PULL_DAUER:-};${ANSIBLE_CHANGED:-};${COMPLIANCE:-};${timer_vorher:-kein Timer};$(date -Is)" >> "$CSV"
}

# --- Die vier Eingriffe ------------------------------------------------------

# 1 Kiosk beendet. Das ist der Absturz, nicht die Manipulation - und der
#   einzige Fall, den die lokale Schicht abfaengt.
inj_kiosk() { systemctl kill -s SIGKILL raumfrei-kiosk.service 2>/dev/null || pkill -9 cage; }

# 2 URL verstellt. Der Klassiker: jemand haengt das Schild an einen anderen
#   Raum. Die Datei ist ein Ansible-Template - der naechste Pull rendert sie
#   neu. systemd merkt davon nichts, die Unit laeuft ja weiter.
inj_url() {
    sed -i 's|^KIOSK_URL=.*|KIOSK_URL=http://127.0.0.1:8080/display.html?room=999|' /etc/raumfrei/kiosk.env
    systemctl restart raumfrei-kiosk.service 2>/dev/null
}

# 3 Paket entfernt. Ohne Browser kein Schild; die Rolle kiosk installiert ihn
#   bei jedem Lauf nach.
inj_paket() { DEBIAN_FRONTEND=noninteractive apt-get remove -y "$BROWSER_PAKET" >/dev/null 2>&1; }

# 4 Autostart aus - und zwar mit mask, nicht nur disable. "systemctl mask" ist
#   das, was jemand tut, der den Kiosk dauerhaft loswerden will, und es
#   ueberlebt ein blosses enable. Genau deshalb steht masked: false in der
#   Rolle.
inj_autostart() {
    systemctl disable --now raumfrei-kiosk.service >/dev/null 2>&1
    systemctl mask raumfrei-kiosk.service >/dev/null 2>&1
}

case "$FALL" in
    kiosk|1)     fall_ausfuehren "1 Kiosk beendet"   "Browserprozess hart beendet"       inj_kiosk     pruef_kiosk     "lokal (systemd Restart=always)" ;;
    url|2)       fall_ausfuehren "2 URL verstellt"   "KIOSK_URL auf einen fremden Raum"  inj_url       pruef_url       "zentral (ansible-pull)" ;;
    paket|3)     fall_ausfuehren "3 Paket entfernt"  "Browserpaket deinstalliert"        inj_paket     pruef_paket     "zentral (ansible-pull)" ;;
    autostart|4) fall_ausfuehren "4 Autostart aus"   "Unit disabled und maskiert"        inj_autostart pruef_autostart "zentral (masked: false)" ;;
    alle)
        fall_ausfuehren "1 Kiosk beendet"  "Browserprozess hart beendet"      inj_kiosk     pruef_kiosk     "lokal (systemd Restart=always)"
        fall_ausfuehren "2 URL verstellt"  "KIOSK_URL auf einen fremden Raum" inj_url       pruef_url       "zentral (ansible-pull)"
        fall_ausfuehren "3 Paket entfernt" "Browserpaket deinstalliert"       inj_paket     pruef_paket     "zentral (ansible-pull)"
        fall_ausfuehren "4 Autostart aus"  "Unit disabled und maskiert"       inj_autostart pruef_autostart "zentral (masked: false)"
        ;;
    *) echo "Unbekannter Fall: ${FALL} (kiosk|url|paket|autostart|alle)" >&2; exit 1 ;;
esac

echo
echo "=============================================================="
echo "Drift-Matrix in ${CSV}:"
echo
column -t -s';' "$CSV" 2>/dev/null || cat "$CSV"
echo
echo "Zur Erinnerung fuer den Bericht: die Spalte pull_dauer_s ist die Dauer"
echo "der Korrektur, nicht die Wartezeit darauf. Die Wartezeit im Betrieb"
echo "steht in naechster_timer und betraegt bis zu einer Lektion."
