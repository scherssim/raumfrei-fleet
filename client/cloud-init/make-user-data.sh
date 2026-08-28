#!/usr/bin/env bash
# make-user-data.sh - aus der Vorlage und den Repo-Dateien eine fertige
# cloud-init user-data bauen.
#
#   ./make-user-data.sh --hostname display-a --kiosk
#   ./make-user-data.sh --hostname agent-07  --headless --out /tmp/agent-07.yaml
#
# Warum ein Generator und keine gepflegte user-data:
#
#   1. Das Enrollment-Secret gehoert ins Image, nicht ins oeffentliche Repo.
#      Eine eingecheckte user-data mit Secret waere genau der Fehler, den
#      diese Arbeit vermeiden will.
#   2. Die Skripte und Units haetten sonst zwei Fassungen - eine in client/
#      und eine eingebettete in der user-data. Die eine laeuft beim Erstboot,
#      die andere beim Pull, und sie wuerden auseinanderlaufen. Hier ist
#      client/ die einzige Quelle; die user-data ist ein Erzeugnis.
#
# Secret und Backend-URL kommen aus backend/secrets.env (von
# deploy_devices.ps1 geschrieben) oder aus den Optionen.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SECRETS="${REPO}/backend/secrets.env"

HOSTNAME_ARG="raumfrei-display"
KIOSK="ja"
OUT="${HERE}/user-data"
BACKEND_URL="${BACKEND_URL:-}"
ENROLL_SECRET="${ENROLL_SECRET:-}"

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname)     HOSTNAME_ARG="$2"; shift 2 ;;
        --kiosk)        KIOSK="ja";        shift ;;
        --headless)     KIOSK="nein";      shift ;;
        --out)          OUT="$2";          shift 2 ;;
        --backend-url)  BACKEND_URL="$2";  shift 2 ;;
        --secret)       ENROLL_SECRET="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        *) echo "Unbekannte Option: $1" >&2; usage 1 ;;
    esac
done

# --- Secrets ----------------------------------------------------------------
if [ -z "$BACKEND_URL" ] || [ -z "$ENROLL_SECRET" ]; then
    if [ -r "$SECRETS" ]; then
        # shellcheck disable=SC1090
        set -a; . "$SECRETS"; set +a
    else
        echo "FEHLER: ${SECRETS} fehlt und weder --backend-url noch --secret gesetzt." >&2
        echo "        Zuerst backend/deploy_devices.ps1 ausfuehren." >&2
        exit 1
    fi
fi
: "${BACKEND_URL:?BACKEND_URL fehlt}"
: "${ENROLL_SECRET:?ENROLL_SECRET fehlt}"

# --- Dateien einbetten -------------------------------------------------------
# base64 statt "content: |": ein eingerueckter Heredoc mit Shell-Code darin ist
# eine Fehlerquelle, die keine Aussage traegt. Die Kodierung macht ausserdem
# CRLF unmoeglich - der Pi antwortet auf ein CRLF-Skript mit
# "/bin/bash^M: bad interpreter".
embed() {   # embed <quelle> <ziel> <modus>
    printf '  - path: %s\n' "$2"
    printf '    owner: root:root\n'
    printf '    permissions: "%s"\n' "$3"
    printf '    encoding: b64\n'
    printf '    content: %s\n' "$(base64 -w0 "$1")"
}

export FILES
FILES="$(
    embed "${REPO}/client/bin/raumfrei-enroll"       /usr/local/sbin/raumfrei-enroll 0750
    embed "${REPO}/client/bin/raumfrei-agent"        /usr/local/sbin/raumfrei-agent  0750
    for unit in "${REPO}"/client/units/*; do
        embed "$unit" "/etc/systemd/system/$(basename "$unit")" 0644
    done
    if [ "$KIOSK" = "ja" ]; then
        # Reine Markierung. Sie entscheidet, ob die Ansible-Rolle kiosk
        # ueberhaupt laeuft - siehe ansible/group_vars/all.yml. Ein Geraet
        # ohne Bildschirm soll weder cage noch einen Browser installieren.
        printf '  - path: /etc/raumfrei/kiosk.enabled\n'
        printf '    owner: root:root\n'
        printf '    permissions: "0644"\n'
        printf '    content: "Dieses Geraet ist ein Tuerschild.\\n"\n'
    fi
)"

# --- Vorlage fuellen ---------------------------------------------------------
# Dieses Skript laeuft auf dem Arbeitsplatz (Git Bash unter Windows), nicht auf
# dem Geraet. Dort heisst der Interpreter "python", auf Linux "python3".
# Geprueft wird durch Ausfuehren, nicht mit command -v: Windows legt fuer
# python3 einen Platzhalter im PATH ab, der nur auf den Microsoft Store
# verweist. command -v findet ihn, und das Skript bricht mit Exit 49 ab.
PY=""
for candidate in python3 python; do
    if "$candidate" -c "" >/dev/null 2>&1; then PY="$candidate"; break; fi
done
[ -n "$PY" ] || { echo "FEHLER: kein lauffaehiges Python gefunden." >&2; exit 1; }

"$PY" - "$HERE/user-data.tmpl" "$OUT" "$HOSTNAME_ARG" "$BACKEND_URL" "$ENROLL_SECRET" <<'PYTHON'
import sys
template, out, hostname, backend_url, secret = sys.argv[1:6]
import os
text = open(template, encoding="utf-8").read()
text = (text.replace("@@HOSTNAME@@", hostname)
            .replace("@@BACKEND_URL@@", backend_url)
            .replace("@@ENROLL_SECRET@@", secret)
            .replace("@@FILES@@", os.environ["FILES"]))
with open(out, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(text)
PYTHON

chmod 600 "$OUT"

echo "user-data geschrieben: $OUT"
echo "  Host       : $HOSTNAME_ARG"
echo "  Backend    : $BACKEND_URL"
echo "  Kiosk      : $KIOSK"
echo "  Groesse    : $(wc -c < "$OUT") Bytes"
echo
echo "ACHTUNG: Die Datei enthaelt das ENROLL_SECRET im Klartext."
echo "         Sie ist gitignored und gehoert nur ins Image."
