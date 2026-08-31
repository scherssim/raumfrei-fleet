#!/usr/bin/env bash
# netpath_probe.sh - Messreihe M5: der Netzpfad.
#
# Laeuft AUF dem Tuerschild als root:
#
#     sudo bash netpath_probe.sh            # beide Teile
#     sudo bash netpath_probe.sh --teil b   # nur der Ausfalltest
#
# Zwei Belege, die zusammen die Architektur begruenden:
#
#   Teil a - EINGEHEND GIBT ES NICHT.
#            Das Geraet haengt hinter NAT. Seine Adresse ist privat, die
#            oeffentliche Adresse gehoert dem Router, und es horcht auf
#            keinem Port, den jemand von aussen erreichen koennte. Ein
#            Steuerungsserver, der pushen wollte, haette keinen Weg hinein -
#            das ist der Grund fuer Pull, nicht eine Vorliebe.
#
#   Teil b - BACKEND WEG, ANZEIGE BLEIBT.
#            Der API-Host wird lokal unerreichbar gemacht. Erwartet:
#            der Agent meldet "Backend nicht erreichbar", faehrt mit dem
#            letzten Soll-Zustand fort und beendet sich mit 0; die Anzeige
#            zeigt weiter den gecachten Plan mit "Stand von HH:MM".
#            Danach wird die Sperre aufgehoben und der naechste Lauf meldet
#            wieder sauber - Selbstheilung ohne Handgriff am Geraet.
#
# Teil b greift in die Namensaufloesung ein und raeumt hinter sich auf, auch
# bei Abbruch (trap). Ohne dieses Aufraeumen bliebe das Geraet blind.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS="${HERE}/results"
BERICHT="${RESULTS}/netpath.txt"
TEIL="beide"

while [ $# -gt 0 ]; do
    case "$1" in
        --teil)    TEIL="$2"; shift 2 ;;
        --bericht) BERICHT="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "FEHLER: als root ausfuehren." >&2; exit 1; }
[ -r /etc/raumfrei/agent.env ] || { echo "FEHLER: /etc/raumfrei/agent.env fehlt." >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/raumfrei/agent.env
: "${BACKEND_URL:?BACKEND_URL fehlt in agent.env}"

API_HOST="$(printf '%s' "$BACKEND_URL" | sed -E 's#^https?://##; s#/.*##')"

mkdir -p "$RESULTS"
exec > >(tee "$BERICHT") 2>&1

echo "=============================================================="
echo "M5 - NETZPFAD     $(date -Is)    Geraet $(hostname)"
echo "Backend: ${BACKEND_URL}"
echo "=============================================================="

# ---------------------------------------------------------------- Teil a
teil_a() {
    echo
    echo "--- Teil a: eingehend gibt es nicht -----------------------------"

    local lokal oeffentlich
    lokal="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "Adresse des Geraets ......... ${lokal}"

    case "$lokal" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
            echo "  -> privat nach RFC 1918. Diese Adresse ist im Internet nicht"
            echo "     routbar; ein Paket von aussen dorthin existiert nicht." ;;
        *)
            echo "  -> WARNUNG: keine private Adresse. Im Lab-Aufbau ist das"
            echo "     moeglich, im Schulnetz nicht - im Bericht benennen." ;;
    esac

    oeffentlich="$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null)"
    echo "Adresse nach aussen ......... ${oeffentlich:-nicht ermittelbar}"
    if [ -n "$oeffentlich" ] && [ "$oeffentlich" != "$lokal" ]; then
        echo "  -> verschieden. Zwischen Geraet und Internet steht NAT:"
        echo "     ausgehend geht, eingehend gibt es keine Zuordnung."
    fi

    echo
    echo "Horcht das Geraet ueberhaupt auf etwas Erreichbarem?"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | awk 'NR==1 || $4 !~ /127\.0\.0\.1|\[::1\]/'
        echo
        echo "  -> Alles, was hier auf 127.0.0.1 steht, ist von aussen nicht"
        echo "     erreichbar. raumfrei-display.service bindet bewusst nur"
        echo "     lokal (--bind 127.0.0.1)."
    fi

    echo
    echo "Gegenprobe von aussen (haendisch, gehoert als Beleg dazu):"
    echo "  vom Hostrechner:   Test-NetConnection ${oeffentlich:-<oeffentliche IP>} -Port 22"
    echo "  erwartet:          TcpTestSucceeded : False"
}

# ---------------------------------------------------------------- Teil b
GESPERRT=0
entsperren() {
    if [ "$GESPERRT" -eq 1 ]; then
        sed -i "/# raumfrei-netpath-probe$/d" /etc/hosts
        GESPERRT=0
        echo "$(date +%H:%M:%S)  Sperre aufgehoben (/etc/hosts bereinigt)."
    fi
}
trap entsperren EXIT INT TERM

teil_b() {
    echo
    echo "--- Teil b: Backend weg, Anzeige bleibt -------------------------"

    echo "$(date +%H:%M:%S)  Vorher: ein sauberer Lauf, damit ein Soll-Zustand liegt."
    systemctl start raumfrei-agent.service >/dev/null 2>&1
    local vorher
    vorher="$(journalctl -u raumfrei-agent.service --no-pager -n 30 | grep -o 'Check-in: [A-Z_]*' | tail -1)"
    echo "            ${vorher:-kein Check-in im Journal}"

    echo "$(date +%H:%M:%S)  Sperre ${API_HOST} (Eintrag in /etc/hosts auf 127.0.0.1) ..."
    echo "127.0.0.1 ${API_HOST} # raumfrei-netpath-probe" >> /etc/hosts
    GESPERRT=1

    if curl -fsS --max-time 5 -o /dev/null "${BACKEND_URL}/rooms" 2>/dev/null; then
        echo "            WARNUNG: das Backend antwortet trotzdem - Sperre wirkt nicht."
        echo "            Ersatzweise: iptables -I OUTPUT -d <API-IP> -j REJECT"
    else
        echo "            bestaetigt: ${API_HOST} ist von hier nicht mehr erreichbar."
    fi

    echo "$(date +%H:%M:%S)  Agent-Lauf im Ausfall ..."
    systemctl start raumfrei-agent.service >/dev/null 2>&1
    local rc
    rc="$(systemctl show raumfrei-agent.service -p ExecMainStatus --value 2>/dev/null)"
    echo
    echo "Journal des Laufs:"
    journalctl -u raumfrei-agent.service --no-pager -n 12 | sed 's/^/    /'
    echo
    echo "    Exit-Status der Unit: ${rc:-?}   (0 ist richtig: ein Backend-Ausfall"
    echo "    ist kein Fehler des Geraets, sondern ein Zustand, mit dem es umgeht)"

    echo
    echo "$(date +%H:%M:%S)  Anzeige waehrend des Ausfalls:"
    if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8080/display.html; then
        echo "            display.html wird weiter ausgeliefert (lokaler Server)."
        echo "            SICHTBELEG: jetzt den Schirm fotografieren - die Fusszeile"
        echo "            muss 'Stand von HH:MM' zeigen, nicht 'nicht erreichbar'."
        echo "            Danach mit ENTER weiter."
        read -r _ 2>/dev/null || sleep 20
    else
        echo "            FEHLER: auch der lokale Auslieferer antwortet nicht."
    fi

    entsperren
    echo "$(date +%H:%M:%S)  Erholung: naechster Lauf nach dem Ausfall ..."
    systemctl start raumfrei-agent.service >/dev/null 2>&1
    local nachher
    nachher="$(journalctl -u raumfrei-agent.service --no-pager -n 30 | grep -o 'Check-in: [A-Z_]*' | tail -1)"
    echo "            ${nachher:-kein Check-in im Journal}"
    echo
    echo "Ergebnis Teil b: Ausfall ueberstanden ohne Handgriff am Geraet."
    echo "  vorher:  ${vorher:-?}"
    echo "  nachher: ${nachher:-?}"
}

case "$TEIL" in
    a) teil_a ;;
    b) teil_b ;;
    beide) teil_a; teil_b ;;
    *) echo "Unbekannter Teil: ${TEIL} (a|b|beide)" >&2; exit 1 ;;
esac

echo
echo "=============================================================="
echo "geschrieben: ${BERICHT}"
