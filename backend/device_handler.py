"""
device_handler.py - Geraeteseite von RaumFrei (Modul Client Management, TEKO SS26).

Ergaenzt die bestehende RaumFrei-Buchungs-API um die Flotten-Endpunkte:

    POST /enroll                     Erstboot: Secret -> Identitaet + Token
    GET  /config/{deviceId}          Soll-Zustand des Geraets (Bearer-Token)
    POST /checkin                    Ist-Zustand melden (Bearer-Token)

    GET  /devices                    Admin: Flottenuebersicht
    POST /devices/{deviceId}/assign  Admin: Raum zuweisen
    POST /devices/{deviceId}/revoke  Admin: Token widerrufen
    POST /devices/{deviceId}/retire  Admin: Geraet ausmustern
    GET  /settings                   Admin: globaler Soll-Zustand
    POST /settings                   Admin: globalen Soll-Zustand aendern

Alles laeuft ueber EINE DynamoDB-Tabelle (PK deviceId) mit drei Item-Typen,
unterschieden durch das Attribut itemType:

    device            deviceId = "d-<12 hex>"        das Geraet
    settings          deviceId = "settings#global"   flottenweiter Soll-Zustand
    nonce             deviceId = "nonce#<nonce>"     Replay-Schutz, mit TTL

Bewusste Entscheide (gehoeren in den Bericht):
  * deviceId ist deterministisch aus der MAC abgeleitet -> Re-Enrollment ist
    idempotent, ohne dass ein GSI auf die MAC noetig waere.
  * Das Enrollment-Secret wandert nie ueber die Leitung; das Geraet weist sich
    mit einem HMAC ueber (mac|ts|nonce) aus.
  * Vom Token wird nur der SHA-256-Hash gespeichert.
  * configVersion ist der Hash des effektiven Soll-Zustands. Jede Aenderung -
    global oder pro Geraet - erzeugt automatisch eine neue Version; es gibt
    keinen Zaehler, den man vergessen koennte hochzuzaehlen.
"""

import hashlib
import hmac
import json
import os
import secrets
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ.get("DEVICES_TABLE", "Devices")
ENROLL_SECRET = os.environ.get("ENROLL_SECRET", "")
ADMIN_KEY = os.environ.get("ADMIN_KEY", "")
DEVICE_ID_SALT = os.environ.get("DEVICE_ID_SALT", "raumfrei")

# Wie weit darf die Uhr des Geraets abweichen (Sekunden). Ohne Fenster waere
# ein abgehoerter Enrollment-Request beliebig lange wiederverwendbar.
MAX_CLOCK_SKEW = 300
NONCE_TTL = 900

SETTINGS_ID = "settings#global"

DEFAULT_SETTINGS = {
    "pullRepo": "https://github.com/simonsscherer/raumfrei-fleet",
    "pullBranch": "main",
    "displayBaseUrl": "http://localhost:8080/display.html",
    "roomsApiUrl": "",
    "checkinIntervalSeconds": 2700,
    "requireApproval": False,
    "kiosk": {
        "browser": "cog",
        "rotate": 0,
        "refreshSeconds": 60,
    },
}

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


# ---------------------------------------------------------------- Hilfsmittel

def respond(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Admin-Key",
        },
        "body": json.dumps(body, ensure_ascii=False, default=str),
    }


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def canonical_mac(mac):
    """dc-a6-32-AB-CD-EF / DCA632ABCDEF / dc:a6:32:ab:cd:ef  ->  dca632abcdef"""
    cleaned = "".join(c for c in str(mac).lower() if c in "0123456789abcdef")
    return cleaned if len(cleaned) == 12 else ""


def device_id_from_mac(mac):
    digest = hashlib.sha256((DEVICE_ID_SALT + mac).encode()).hexdigest()
    return "d-" + digest[:12]


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def header(event, name, default=""):
    headers = event.get("headers") or {}
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return default


def body_of(event):
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return None


def get_settings():
    item = table.get_item(Key={"deviceId": SETTINGS_ID}).get("Item")
    settings = dict(DEFAULT_SETTINGS)
    if item:
        for key, value in item.items():
            if key not in ("deviceId", "itemType"):
                settings[key] = value
    return settings


def get_device(device_id):
    item = table.get_item(Key={"deviceId": device_id}).get("Item")
    if item and item.get("itemType") == "device":
        return item
    return None


# ------------------------------------------------------------ Soll-Zustand

def desired_config(device, settings):
    """Effektiver Soll-Zustand eines Geraets: global + geraetespezifisch."""
    room_id = device.get("roomId")
    kiosk = dict(settings.get("kiosk") or {})
    kiosk.update(device.get("kioskOverride") or {})

    display_url = None
    if room_id:
        base = settings.get("displayBaseUrl", DEFAULT_SETTINGS["displayBaseUrl"])
        display_url = base + "?room=" + str(room_id)

    config = {
        "deviceId": device["deviceId"],
        "roomId": room_id,
        "displayUrl": display_url,
        "roomsApiUrl": settings.get("roomsApiUrl", ""),
        "pullRepo": settings.get("pullRepo"),
        "pullBranch": settings.get("pullBranch"),
        "checkinIntervalSeconds": int(settings.get("checkinIntervalSeconds", 2700)),
        "kiosk": kiosk,
        "status": device.get("status", "PENDING"),
    }
    config["configVersion"] = config_version(config)
    return config


def config_version(config):
    """Version = Hash des Soll-Zustands. Aendert sich genau dann, wenn sich
    inhaltlich etwas aendert - egal ob global oder pro Geraet."""
    payload = {k: v for k, v in config.items() if k != "configVersion"}
    blob = json.dumps(payload, sort_keys=True, ensure_ascii=False, default=str)
    return hashlib.sha256(blob.encode()).hexdigest()[:12]


# ------------------------------------------------------------------ Auth

def verify_enroll(payload):
    """Prueft HMAC, Zeitfenster und Einmaligkeit der Nonce."""
    mac = canonical_mac(payload.get("mac", ""))
    nonce = str(payload.get("nonce", ""))
    given = str(payload.get("hmac", ""))

    if not mac:
        return "MAC fehlt oder ist ungueltig.", 400
    if not nonce or len(nonce) < 16:
        return "nonce fehlt oder ist zu kurz (min. 16 Zeichen).", 400
    if not ENROLL_SECRET:
        return "Backend ist nicht konfiguriert (ENROLL_SECRET fehlt).", 500

    try:
        ts = int(payload.get("ts", 0))
    except (TypeError, ValueError):
        return "ts ist keine Zahl.", 400

    skew = abs(int(time.time()) - ts)
    if skew > MAX_CLOCK_SKEW:
        return "Zeitversatz " + str(skew) + "s ueberschreitet " + str(MAX_CLOCK_SKEW) + "s.", 403

    expected = hmac.new(
        ENROLL_SECRET.encode(),
        (mac + "|" + str(ts) + "|" + nonce).encode(),
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(expected, given.lower()):
        return "HMAC stimmt nicht.", 401

    # Nonce genau einmal verbrauchen. Der ConditionExpression macht daraus eine
    # atomare Operation - zwei gleichzeitige Replays koennen sich nicht beide
    # durchsetzen.
    try:
        table.put_item(
            Item={
                "deviceId": "nonce#" + nonce,
                "itemType": "nonce",
                "expiresAt": int(time.time()) + NONCE_TTL,
            },
            ConditionExpression="attribute_not_exists(deviceId)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return "Nonce wurde bereits verwendet (Replay).", 409
        raise

    return None, 0


def authenticate(event):
    """Bearer-Token pruefen. Gibt (device, fehlerantwort) zurueck."""
    auth = header(event, "Authorization")
    if not auth.lower().startswith("bearer "):
        return None, respond(401, {"message": "Authorization: Bearer <token> fehlt."})

    token = auth.split(" ", 1)[1].strip()
    path_params = event.get("pathParameters") or {}
    device_id = path_params.get("deviceId") or (body_of(event) or {}).get("deviceId")

    if not device_id:
        return None, respond(400, {"message": "deviceId fehlt."})

    device = get_device(device_id)
    if not device:
        return None, respond(404, {"message": "Unbekanntes Geraet '" + str(device_id) + "'."})

    if not hmac.compare_digest(device.get("tokenHash", ""), token_hash(token)):
        return None, respond(401, {"message": "Token ungueltig."})

    if device.get("status") in ("REVOKED", "RETIRED"):
        return None, respond(
            403,
            {
                "message": "Geraet ist " + device["status"] + ".",
                "status": device["status"],
                "action": "wipe",
            },
        )

    return device, None


def require_admin(event):
    if not ADMIN_KEY:
        return respond(500, {"message": "Backend ist nicht konfiguriert (ADMIN_KEY fehlt)."})
    if not hmac.compare_digest(header(event, "X-Admin-Key"), ADMIN_KEY):
        return respond(401, {"message": "X-Admin-Key fehlt oder ist falsch."})
    return None


# ------------------------------------------------------------- Endpunkte

def enroll(event):
    payload = body_of(event)
    if payload is None:
        return respond(400, {"message": "Body ist kein gueltiges JSON."})

    error, status = verify_enroll(payload)
    if error:
        return respond(status, {"message": error})

    mac = canonical_mac(payload["mac"])
    device_id = device_id_from_mac(mac)
    settings = get_settings()
    existing = get_device(device_id)

    if existing and existing.get("status") in ("REVOKED", "RETIRED"):
        return respond(
            403,
            {
                "message": "Geraet ist " + existing["status"] + " und darf sich nicht neu anmelden.",
                "deviceId": device_id,
            },
        )

    token = secrets.token_urlsafe(32)
    status_new = "PENDING" if settings.get("requireApproval") else "ACTIVE"

    item = {
        "deviceId": device_id,
        "itemType": "device",
        "mac": mac,
        "hostname": str(payload.get("hostname", ""))[:64],
        "model": str(payload.get("model", ""))[:64],
        "tokenHash": token_hash(token),
        "status": existing.get("status") if existing else status_new,
        "roomId": existing.get("roomId") if existing else None,
        "enrolledAt": existing.get("enrolledAt") if existing else now_iso(),
        "lastEnrollAt": now_iso(),
        "enrollCount": (int(existing.get("enrollCount", 0)) + 1) if existing else 1,
        "kioskOverride": existing.get("kioskOverride") if existing else None,
    }
    table.put_item(Item=item)

    config = desired_config(item, settings)
    return respond(
        200,
        {
            "deviceId": device_id,
            "token": token,
            "roomId": item["roomId"],
            "status": item["status"],
            "configVersion": config["configVersion"],
            "reEnrollment": bool(existing),
        },
    )


def config(event):
    device, error = authenticate(event)
    if error:
        return error
    return respond(200, desired_config(device, get_settings()))


def checkin(event):
    device, error = authenticate(event)
    if error:
        return error

    report = body_of(event)
    if report is None:
        return respond(400, {"message": "Body ist kein gueltiges JSON."})

    settings = get_settings()
    desired = desired_config(device, settings)

    ansible = report.get("ansible") or {}
    failed = int(ansible.get("failed", 0) or 0)
    changed = int(ansible.get("changed", 0) or 0)
    reported_version = report.get("configVersion", "")

    if failed > 0:
        compliance = "FAILED"
    elif changed > 0:
        # Der Pull hat Abweichungen gefunden UND korrigiert. Genau das ist Drift.
        compliance = "DRIFT"
    elif reported_version and reported_version != desired["configVersion"]:
        compliance = "PENDING_CONFIG"
    else:
        compliance = "COMPLIANT"

    table.update_item(
        Key={"deviceId": device["deviceId"]},
        UpdateExpression=(
            "SET lastCheckin = :t, lastReport = :r, compliance = :c, "
            "reportedConfigVersion = :v, agentVersion = :a, "
            "checkinCount = if_not_exists(checkinCount, :zero) + :one"
        ),
        ExpressionAttributeValues={
            ":t": now_iso(),
            ":r": report,
            ":c": compliance,
            ":v": reported_version,
            ":a": str(report.get("agentVersion", ""))[:32],
            ":zero": 0,
            ":one": 1,
        },
    )

    return respond(
        200,
        {
            "compliance": compliance,
            "desiredConfigVersion": desired["configVersion"],
            # Kein Push: das ist die Antwort auf einen Pull, nicht ein Befehl,
            # den das Backend von sich aus senden koennte.
            "action": "wipe" if device.get("status") in ("REVOKED", "RETIRED") else "none",
            "serverTime": now_iso(),
        },
    )


# --------------------------------------------------------------- Admin

def list_devices(event):
    settings = get_settings()
    interval = int(settings.get("checkinIntervalSeconds", 2700))
    items, start_key = [], None

    while True:
        kwargs = {
            "FilterExpression": "itemType = :t",
            "ExpressionAttributeValues": {":t": "device"},
        }
        if start_key:
            kwargs["ExclusiveStartKey"] = start_key
        page = table.scan(**kwargs)
        items.extend(page.get("Items", []))
        start_key = page.get("LastEvaluatedKey")
        if not start_key:
            break

    now = datetime.now(timezone.utc)
    for item in items:
        item.pop("tokenHash", None)
        item["desiredConfigVersion"] = desired_config(item, settings)["configVersion"]
        last = item.get("lastCheckin")
        item["staleSeconds"] = None
        if last:
            age = (now - datetime.fromisoformat(last)).total_seconds()
            item["staleSeconds"] = int(age)
            if age > 2 * interval:
                item["compliance"] = "STALE"
        elif item.get("status") == "ACTIVE":
            item["compliance"] = "STALE"

    items.sort(key=lambda d: (d.get("roomId") or "~", d["deviceId"]))
    return respond(200, {"count": len(items), "devices": items, "settings": settings})


def admin_device_action(event, action):
    path_params = event.get("pathParameters") or {}
    device_id = path_params.get("deviceId")
    device = get_device(device_id) if device_id else None
    if not device:
        return respond(404, {"message": "Unbekanntes Geraet '" + str(device_id) + "'."})

    payload = body_of(event) or {}

    if action == "assign":
        room_id = str(payload.get("roomId", "")).strip()
        if not room_id:
            return respond(400, {"message": "roomId ist erforderlich."})
        table.update_item(
            Key={"deviceId": device_id},
            UpdateExpression="SET roomId = :r, #s = :a, assignedAt = :t",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":r": room_id, ":a": "ACTIVE", ":t": now_iso()},
        )
        message = "Geraet '" + device_id + "' ist neu Raum '" + room_id + "' zugewiesen."

    elif action in ("revoke", "retire"):
        new_status = "REVOKED" if action == "revoke" else "RETIRED"
        table.update_item(
            Key={"deviceId": device_id},
            UpdateExpression="SET #s = :s, statusChangedAt = :t REMOVE tokenHash",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": new_status, ":t": now_iso()},
        )
        message = "Geraet '" + device_id + "' ist neu " + new_status + "."

    else:
        return respond(404, {"message": "Unbekannte Aktion '" + str(action) + "'."})

    updated = get_device(device_id)
    return respond(
        200,
        {
            "message": message,
            "deviceId": device_id,
            "status": updated.get("status"),
            "roomId": updated.get("roomId"),
            "desiredConfigVersion": desired_config(updated, get_settings())["configVersion"],
        },
    )


def update_settings(event):
    payload = body_of(event)
    if payload is None:
        return respond(400, {"message": "Body ist kein gueltiges JSON."})

    settings = get_settings()
    for key, value in payload.items():
        if key in ("deviceId", "itemType"):
            continue
        if key not in DEFAULT_SETTINGS:
            return respond(400, {"message": "Unbekannte Einstellung '" + str(key) + "'."})
        settings[key] = value

    item = {"deviceId": SETTINGS_ID, "itemType": "settings"}
    item.update(settings)
    table.put_item(Item=item)
    return respond(200, {"message": "Globaler Soll-Zustand aktualisiert.", "settings": settings})


# --------------------------------------------------------------- Router

ADMIN_ROUTES = {
    "GET /devices",
    "POST /devices/{deviceId}/assign",
    "POST /devices/{deviceId}/revoke",
    "POST /devices/{deviceId}/retire",
    "GET /settings",
    "POST /settings",
}


def lambda_handler(event, context):
    http = (event.get("requestContext") or {}).get("http") or {}
    method = http.get("method", "GET")
    route = event.get("routeKey") or (method + " " + event.get("rawPath", "/"))

    if method == "OPTIONS":
        return respond(200, {})

    if route in ADMIN_ROUTES:
        denied = require_admin(event)
        if denied:
            return denied

    try:
        if route == "POST /enroll":
            return enroll(event)
        if route == "GET /config/{deviceId}":
            return config(event)
        if route == "POST /checkin":
            return checkin(event)
        if route == "GET /devices":
            return list_devices(event)
        if route == "POST /devices/{deviceId}/assign":
            return admin_device_action(event, "assign")
        if route == "POST /devices/{deviceId}/revoke":
            return admin_device_action(event, "revoke")
        if route == "POST /devices/{deviceId}/retire":
            return admin_device_action(event, "retire")
        if route == "GET /settings":
            return respond(200, {"settings": get_settings()})
        if route == "POST /settings":
            return update_settings(event)
    except ClientError as exc:
        print("AWS-Fehler bei " + route + ": " + str(exc))
        return respond(502, {"message": "Backend-Fehler gegen DynamoDB.", "detail": str(exc)})

    return respond(404, {"message": "Route nicht gefunden: " + route})
