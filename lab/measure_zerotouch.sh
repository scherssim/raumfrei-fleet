#!/usr/bin/env bash
# measure_zerotouch.sh - Messreihe M1: Boot -> Raumplan sichtbar.
#
# Laeuft AUF dem Tuerschild, nach einem Erstboot, als root:
#
#     sudo bash measure_zerotouch.sh --lauf 1
#
# Liest die Zeitmarken aus dem Journal des laufenden Boots und haengt eine
# Zeile an results/zerotouch.csv. Fuer n=5 die VM fuenfmal frisch aufsetzen
# (siehe lab/README.md, Abschnitt "M1 wiederholen") und den Lauf jeweils
# hochzaehlen.
#
# Gemessen wird in fuenf Abschnitten, weil "3 Minuten bis zum Raumplan" als
# Zahl nichts erklaert. Erst die Aufteilung zeigt, wo die Zeit liegt - und
# genau das ist die Aussage: der Anteil, den die Zero-Touch-Kette selbst
# verantwortet (Enrollment, Pull, Kiosk), ist klein gegen Boot und apt.
#
#     t0  Boot            Einschalten -> Kernel und systemd stehen
#     t1  cloud-init      Erstkonfiguration fertig (cloud-final.service)
#     t2  Enrollment      Secret -> Identitaet, /etc/raumfrei/device.json
#     t3  erster Pull     ansible-pull hat den Soll-Zustand hergestellt
#     t4  Kiosk           Browser startet auf die Anzeigeseite
#
# Alle Marken kommen aus systemd, nicht aus eigenen Zeitnahmen im Skript:
# systemd protokolliert "Starting" und "Finished" je Unit ohnehin, und diese
# Marken sind nachpruefbar, ohne dem Messskript glauben zu muessen.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS="${HERE}/results"
CSV="${RESULTS}/zerotouch.csv"
LAUF=""
LABEL="$(hostname)"
ROH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --lauf)   LAUF="$2";    shift 2 ;;
        --label)  LABEL="$2";   shift 2 ;;
        --csv)    CSV="$2";     shift 2 ;;
        --roh)    ROH="$2";     shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "FEHLER: als root ausfuehren (journalctl braucht die Rechte)." >&2
    exit 1
fi

command -v journalctl >/dev/null 2>&1 || { echo "FEHLER: kein journalctl." >&2; exit 1; }

# --- Zeitmarken --------------------------------------------------------------
# journalctl -o short-unix gibt die Epoche mit Bruchteil als erstes Feld.
# "-b" begrenzt auf den laufenden Boot; ein zweiter Boot verfaelscht die
# Messung sonst still, weil dieselbe Unit erneut "Finished" meldet.

marke() {
    # marke <unit> <muster> -> Epoche des ERSTEN Treffers, leer wenn keiner
    journalctl -b -u "$1" -o short-unix --no-pager 2>/dev/null \
        | grep -m1 -E "$2" | awk '{print $1}'
}

marke_frei() {
    # dasselbe ohne Unit-Filter (fuer Meldungen des Kernels/cloud-init)
    journalctl -b -o short-unix --no-pager 2>/dev/null \
        | grep -m1 -E "$1" | awk '{print $1}'
}

# t0: Bootzeitpunkt. uptime -s ist sekundengenau und stammt nicht aus dem
# Journal - damit haengt der Nullpunkt nicht davon ab, wann das Journal
# seinen ersten Satz geschrieben hat.
T0="$(date -d "$(uptime -s)" +%s 2>/dev/null)"
[ -n "$T0" ] || T0="$(journalctl -b -o short-unix --no-pager | head -1 | awk '{print $1}')"

T1="$(marke cloud-final.service 'Finished|Started')"
[ -n "$T1" ] || T1="$(marke_frei 'Cloud-init .* finished')"

T2="$(marke raumfrei-enroll.service 'Finished|Deactivated successfully')"
T2_START="$(marke raumfrei-enroll.service 'Starting')"

T3="$(marke raumfrei-agent.service 'Finished|Deactivated successfully')"
T3_START="$(marke raumfrei-agent.service 'Starting')"

# Der Kiosk gilt als oben, sobald raumfrei-kiosk-start den Browser startet -
# das ist die Zeile "Browser <name> auf <url>". Faellt sie aus (aelterer
# Stand des Skripts), wird ersatzweise der Unit-Start genommen.
T4="$(marke raumfrei-kiosk.service 'Browser .* auf ')"
[ -n "$T4" ] || T4="$(marke raumfrei-kiosk.service 'Started')"

fehlt=""
for name in T1 T2 T3 T4; do
    eval "wert=\$$name"
    [ -n "$wert" ] || fehlt="${fehlt} ${name}"
done

delta() {
    # delta <von> <bis> -> Sekunden mit einer Nachkommastelle, "" wenn eines fehlt
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo ""; return; }
    awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'
}

D_BOOT="$(delta "$T0" "$T1")"
D_ENROLL="$(delta "${T2_START:-$T1}" "$T2")"
D_WARTEN="$(delta "$T1" "${T2_START:-$T1}")"
D_PULL="$(delta "${T3_START:-$T2}" "$T3")"
D_KIOSK="$(delta "$T3" "$T4")"
D_TOTAL="$(delta "$T0" "$T4")"

# --- Ausgabe -----------------------------------------------------------------
echo "=============================================================="
echo "M1 - Zero Touch auf ${LABEL}${LAUF:+   (Lauf ${LAUF})}"
echo "=============================================================="
printf "  %-28s %8s s\n" "Boot und cloud-init"        "${D_BOOT:-?}"
printf "  %-28s %8s s\n" "Wartezeit bis Enrollment"   "${D_WARTEN:-?}"
printf "  %-28s %8s s\n" "Enrollment (Secret->ID)"    "${D_ENROLL:-?}"
printf "  %-28s %8s s\n" "erster ansible-pull"        "${D_PULL:-?}"
printf "  %-28s %8s s\n" "Kiosk bis Browserstart"     "${D_KIOSK:-?}"
echo "  --------------------------------------------"
printf "  %-28s %8s s\n" "GESAMT Boot -> Raumplan"    "${D_TOTAL:-?}"
echo

if [ -n "$fehlt" ]; then
    echo "WARNUNG: keine Zeitmarke gefunden fuer:${fehlt}"
    echo "         Das heisst in aller Regel, dass die Kette an dieser Stelle"
    echo "         stehengeblieben ist. Nachsehen mit:"
    echo "           journalctl -b -u raumfrei-enroll -u raumfrei-agent -u raumfrei-kiosk"
    echo
fi

# --- Ist-Zustand mitschreiben ------------------------------------------------
# Ohne diese vier Werte ist eine schnelle Zeit wertlos: gemessen wird, wie
# lange es bis zum richtigen Raumplan dauert, nicht bis zu irgendeinem Bild.
DEVICE_ID="$(python3 -c 'import json;print(json.load(open("/etc/raumfrei/device.json"))["deviceId"])' 2>/dev/null || echo "-")"
ROOM_ID="$(python3 -c 'import json;print(json.load(open("/etc/raumfrei/desired.json")).get("roomId") or "-")' 2>/dev/null || echo "-")"
KIOSK_AKTIV="nein"; systemctl is-active --quiet raumfrei-kiosk.service && KIOSK_AKTIV="ja"
SEITE_OK="nein"; curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8080/display.html 2>/dev/null && SEITE_OK="ja"

echo "  Geraet ${DEVICE_ID} · Raum ${ROOM_ID} · Kiosk aktiv: ${KIOSK_AKTIV} · Seite erreichbar: ${SEITE_OK}"
echo

mkdir -p "$RESULTS"
if [ ! -s "$CSV" ]; then
    echo "lauf;geraet;deviceId;roomId;boot_cloudinit_s;wartezeit_s;enroll_s;pull_s;kiosk_s;total_s;kiosk_aktiv;seite_ok;gemessen_am" > "$CSV"
fi
echo "${LAUF:-1};${LABEL};${DEVICE_ID};${ROOM_ID};${D_BOOT};${D_WARTEN};${D_ENROLL};${D_PULL};${D_KIOSK};${D_TOTAL};${KIOSK_AKTIV};${SEITE_OK};$(date -Is)" >> "$CSV"
echo "angehaengt an ${CSV}"

# Rohdaten fuer den Anhang: das ungefilterte Journal der vier Units. Die
# ausgewertete CSV kommt ins Repo, die Rohdaten bleiben lokal (.gitignore).
if [ -n "$ROH" ] || [ -d "${RESULTS}/raw" ]; then
    ROH="${ROH:-${RESULTS}/raw/journal-${LABEL}-lauf${LAUF:-1}.txt}"
    mkdir -p "$(dirname "$ROH")"
    journalctl -b -o short-unix --no-pager \
        -u cloud-final.service -u raumfrei-enroll.service \
        -u raumfrei-agent.service -u raumfrei-display.service \
        -u raumfrei-kiosk.service > "$ROH" 2>/dev/null
    echo "Rohjournal: ${ROH}"
fi

# --- Sichtbeleg --------------------------------------------------------------
# M1 verlangt einen Screenshot mit der Uhrzeit im Bild. grim spricht Wayland
# direkt an und braucht die Sitzung des Anzeige-Nutzers - deshalb der Umweg
# ueber die Umgebungsvariablen des laufenden cage.
if command -v grim >/dev/null 2>&1; then
    UID_DISPLAY="$(id -u display 2>/dev/null)"
    SOCKET="$(ls /run/user/${UID_DISPLAY:-0}/wayland-* 2>/dev/null | head -1)"
    if [ -n "$SOCKET" ]; then
        SHOT="${RESULTS}/raw/M1-${LABEL}-lauf${LAUF:-1}-$(date +%H%M%S).png"
        mkdir -p "$(dirname "$SHOT")"
        XDG_RUNTIME_DIR="/run/user/${UID_DISPLAY}" \
        WAYLAND_DISPLAY="$(basename "$SOCKET")" \
        sudo -u display grim "$SHOT" 2>/dev/null \
            && echo "Screenshot: ${SHOT}" \
            || echo "Hinweis: grim konnte nicht auf die Sitzung zugreifen - Foto vom Schirm tut es auch."
    fi
else
    echo "Hinweis: grim ist nicht installiert (apt install grim) - fuer den"
    echo "         Sichtbeleg genuegt sonst ein Foto des Schirms mit sichtbarer Uhr."
fi
