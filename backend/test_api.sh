#!/usr/bin/env bash
# test_api.sh - Smoke-Test gegen die DEPLOYTE API.
#
# Liest BACKEND_URL, ENROLL_SECRET und ADMIN_KEY aus secrets.env (wird von
# deploy_devices.ps1 geschrieben) und faehrt den kompletten Lebenszyklus eines
# Geraets durch: anmelden -> Config holen -> Raum zuweisen -> Check-in ->
# widerrufen. Dazu die Fehlerfaelle, die im Bericht als Beleg dienen.
#
#   bash test_api.sh
#
# Die verwendete Test-MAC ist fix, damit der Lauf wiederholbar ist. Am Ende
# wird das Testgeraet ausgemustert, damit es die Flottenmessungen nicht stoert.

set -uo pipefail
cd "$(dirname "$0")"

if [ ! -f secrets.env ]; then
    echo "secrets.env fehlt - zuerst deploy_devices.ps1 ausfuehren." >&2
    exit 1
fi
# shellcheck disable=SC1091
set -a; . ./secrets.env; set +a

TEST_MAC="02:00:00:aa:bb:cc"
PASS=0
FAIL=0

check() {  # check <name> <erwarteter status> <tatsaechlicher status> [body]
    if [ "$2" = "$3" ]; then
        printf '  [OK  ] %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  [FEHL] %s  (erwartet %s, war %s)\n     %s\n' "$1" "$2" "$3" "${4:-}"
        FAIL=$((FAIL + 1))
    fi
}

# Antwort und Statuscode in einem Aufruf: Body, dann Status in der letzten Zeile.
req() {  # req <methode> <pfad> [body] [header...]
    local method="$1" path="$2" body="${3:-}"
    shift 3 2>/dev/null || shift 2
    local args=(-s -w '\n%{http_code}' -X "$method" "${BACKEND_URL}${path}"
                -H 'Content-Type: application/json')
    for h in "$@"; do args+=(-H "$h"); done
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}"
}

sign() {  # sign <mac> <ts> <nonce>  -> HMAC-SHA256 hex
    printf '%s|%s|%s' "$1" "$2" "$3" \
        | openssl dgst -sha256 -hmac "$ENROLL_SECRET" -hex \
        | sed 's/^.*= //'
}

canon_mac() { echo "$1" | tr 'A-Z' 'a-z' | tr -cd '0-9a-f'; }

echo
echo "=== Backend: $BACKEND_URL"
echo

# --- 1 Enrollment -----------------------------------------------------------
echo "1 Enrollment"
MAC=$(canon_mac "$TEST_MAC")
TS=$(date +%s)
NONCE=$(openssl rand -hex 16)
SIG=$(sign "$MAC" "$TS" "$NONCE")

OUT=$(req POST /enroll "{\"mac\":\"$MAC\",\"hostname\":\"smoketest\",\"model\":\"curl\",\"ts\":$TS,\"nonce\":\"$NONCE\",\"hmac\":\"$SIG\"}")
CODE=$(echo "$OUT" | tail -1); BODY=$(echo "$OUT" | sed '$d')
check "Enrollment mit gueltigem HMAC" 200 "$CODE" "$BODY"

DEVICE_ID=$(echo "$BODY" | python -c "import json,sys; print(json.load(sys.stdin).get('deviceId',''))")
TOKEN=$(echo "$BODY" | python -c "import json,sys; print(json.load(sys.stdin).get('token',''))")
echo "       deviceId: $DEVICE_ID"

OUT=$(req POST /enroll "{\"mac\":\"$MAC\",\"hostname\":\"smoketest\",\"ts\":$TS,\"nonce\":\"$NONCE\",\"hmac\":\"$SIG\"}")
check "Replay desselben Requests" 409 "$(echo "$OUT" | tail -1)"

TS2=$(date +%s); NONCE2=$(openssl rand -hex 16)
OUT=$(req POST /enroll "{\"mac\":\"$MAC\",\"ts\":$TS2,\"nonce\":\"$NONCE2\",\"hmac\":\"00\"}")
check "Falsches HMAC" 401 "$(echo "$OUT" | tail -1)"

TS3=$(($(date +%s) - 3600)); NONCE3=$(openssl rand -hex 16)
OUT=$(req POST /enroll "{\"mac\":\"$MAC\",\"ts\":$TS3,\"nonce\":\"$NONCE3\",\"hmac\":\"$(sign "$MAC" "$TS3" "$NONCE3")\"}")
check "Zeitversatz eine Stunde" 403 "$(echo "$OUT" | tail -1)"

# --- 2 Config ---------------------------------------------------------------
echo
echo "2 Config"
OUT=$(req GET "/config/$DEVICE_ID" "" "Authorization: Bearer $TOKEN")
check "Config mit gueltigem Token" 200 "$(echo "$OUT" | tail -1)" "$(echo "$OUT" | sed '$d')"

OUT=$(req GET "/config/$DEVICE_ID" "" "Authorization: Bearer falsch")
check "Config mit falschem Token" 401 "$(echo "$OUT" | tail -1)"

OUT=$(req GET "/config/$DEVICE_ID")
check "Config ohne Token" 401 "$(echo "$OUT" | tail -1)"

# --- 3 Admin ----------------------------------------------------------------
echo
echo "3 Admin"
OUT=$(req POST "/devices/$DEVICE_ID/assign" '{"roomId":"IT-LABOR"}')
check "Zuweisung ohne Admin-Key" 401 "$(echo "$OUT" | tail -1)"

OUT=$(req POST "/devices/$DEVICE_ID/assign" '{"roomId":"IT-LABOR"}' "X-Admin-Key: $ADMIN_KEY")
check "Zuweisung mit Admin-Key" 200 "$(echo "$OUT" | tail -1)" "$(echo "$OUT" | sed '$d')"

OUT=$(req GET "/config/$DEVICE_ID" "" "Authorization: Bearer $TOKEN")
BODY=$(echo "$OUT" | sed '$d')
ROOM=$(echo "$BODY" | python -c "import json,sys; print(json.load(sys.stdin).get('roomId',''))")
VERSION=$(echo "$BODY" | python -c "import json,sys; print(json.load(sys.stdin).get('configVersion',''))")
check "Raum ist nach der Zuweisung im Soll-Zustand" "IT-LABOR" "$ROOM" "$BODY"

# --- 4 Check-in -------------------------------------------------------------
echo
echo "4 Check-in"
OUT=$(req POST /checkin "{\"deviceId\":\"$DEVICE_ID\",\"configVersion\":\"$VERSION\",\"agentVersion\":\"smoketest\",\"ansible\":{\"ok\":10,\"changed\":0,\"failed\":0,\"duration\":4.7},\"kioskActive\":true}" "Authorization: Bearer $TOKEN")
BODY=$(echo "$OUT" | sed '$d')
COMPLIANCE=$(echo "$BODY" | python -c "import json,sys; print(json.load(sys.stdin).get('compliance',''))")
check "Sauberer Lauf meldet COMPLIANT" "COMPLIANT" "$COMPLIANCE" "$BODY"

OUT=$(req POST /checkin "{\"deviceId\":\"$DEVICE_ID\",\"configVersion\":\"$VERSION\",\"ansible\":{\"ok\":8,\"changed\":2,\"failed\":0,\"duration\":12.4}}" "Authorization: Bearer $TOKEN")
COMPLIANCE=$(echo "$OUT" | sed '$d' | python -c "import json,sys; print(json.load(sys.stdin).get('compliance',''))")
check "Korrigierte Drift meldet DRIFT" "DRIFT" "$COMPLIANCE"

# --- 5 Flotte und Widerruf --------------------------------------------------
echo
echo "5 Flotte und Lifecycle"
OUT=$(req GET /devices "" "X-Admin-Key: $ADMIN_KEY")
check "Flottenuebersicht" 200 "$(echo "$OUT" | tail -1)"
echo "$OUT" | sed '$d' | python -c "import json,sys; d=json.load(sys.stdin); print('       Geraete in der Flotte:', d.get('count'))"

OUT=$(req POST "/devices/$DEVICE_ID/revoke" '{}' "X-Admin-Key: $ADMIN_KEY")
check "Widerruf" 200 "$(echo "$OUT" | tail -1)"

OUT=$(req GET "/config/$DEVICE_ID" "" "Authorization: Bearer $TOKEN")
CODE=$(echo "$OUT" | tail -1)
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
    check "Widerrufenes Geraet bekommt keine Config" "$CODE" "$CODE"
else
    check "Widerrufenes Geraet bekommt keine Config" "401/403" "$CODE"
fi

OUT=$(req POST "/devices/$DEVICE_ID/retire" '{}' "X-Admin-Key: $ADMIN_KEY")
check "Testgeraet ausgemustert" 200 "$(echo "$OUT" | tail -1)"

echo
echo "=========================================="
echo "  $PASS bestanden, $FAIL fehlgeschlagen"
echo "=========================================="
echo
[ "$FAIL" -eq 0 ] || exit 1
