"""
test_local.py - faehrt device_handler.py komplett ohne AWS durch.

DynamoDB wird durch eine In-Memory-Tabelle ersetzt, die genau die drei
Operationen nachbildet, die der Handler benutzt: get_item, put_item (mit
ConditionExpression attribute_not_exists), update_item (SET/REMOVE) und scan
(mit FilterExpression auf itemType).

    python test_local.py

Zweck: die Enrollment- und Compliance-Logik ist testbar, bevor irgendetwas in
der Cloud steht - und der Testlauf ist zugleich der Beleg fuers Kapitel
"Testing" (Fehlerfaelle inklusive, nicht nur der Happy Path).
"""

import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import time
import types
from copy import deepcopy

os.environ.setdefault("DEVICES_TABLE", "DevicesTest")
os.environ.setdefault("ENROLL_SECRET", "test-enroll-secret")
os.environ.setdefault("ADMIN_KEY", "test-admin-key")
os.environ.setdefault("DEVICE_ID_SALT", "test-salt")


# --------------------------------------------------- DynamoDB-Attrappe

class ConditionalCheckFailed(Exception):
    pass


class FakeClientError(Exception):
    def __init__(self, code, message="fake"):
        super().__init__(message)
        self.response = {"Error": {"Code": code, "Message": message}}


def kein_float(value, pfad="item"):
    """Bildet nach, dass DynamoDB keine Kommazahlen annimmt.

    boto3 lehnt sie mit "Float types are not supported. Use Decimal types
    instead." ab. Diese Attrappe hat das lange NICHT nachgebildet - und genau
    darin ist der erste Check-in eines echten Geraets untergegangen: hier 44
    Pruefungen gruen, in AWS eine 500. Eine Attrappe, die grosszuegiger ist
    als das Original, macht die ganze Testreihe wertlos.
    """
    if isinstance(value, float):
        raise TypeError(
            "Float types are not supported. Use Decimal types instead. (%s)" % pfad)
    if isinstance(value, dict):
        for schluessel, wert in value.items():
            kein_float(wert, "%s.%s" % (pfad, schluessel))
    elif isinstance(value, list):
        for i, wert in enumerate(value):
            kein_float(wert, "%s[%d]" % (pfad, i))


class FakeTable:
    def __init__(self):
        self.items = {}
        self.calls = {"get_item": 0, "put_item": 0, "update_item": 0, "scan": 0}

    def get_item(self, Key):
        self.calls["get_item"] += 1
        item = self.items.get(Key["deviceId"])
        return {"Item": deepcopy(item)} if item else {}

    def put_item(self, Item, ConditionExpression=None):
        self.calls["put_item"] += 1
        kein_float(Item, "put_item")
        if ConditionExpression == "attribute_not_exists(deviceId)" and Item["deviceId"] in self.items:
            raise FakeClientError("ConditionalCheckFailedException")
        self.items[Item["deviceId"]] = deepcopy(Item)
        return {}

    def update_item(self, Key, UpdateExpression, ExpressionAttributeValues=None,
                    ExpressionAttributeNames=None):
        self.calls["update_item"] += 1
        kein_float(ExpressionAttributeValues or {}, "update_item")
        item = self.items.setdefault(Key["deviceId"], dict(Key))
        names = ExpressionAttributeNames or {}
        values = ExpressionAttributeValues or {}

        set_part = UpdateExpression
        remove_part = ""
        if " REMOVE " in UpdateExpression:
            set_part, remove_part = UpdateExpression.split(" REMOVE ", 1)

        set_part = set_part.replace("SET ", "", 1)
        # Nur an Kommas trennen, die eine neue Zuweisung einleiten - sonst
        # zerreisst es "if_not_exists(feld, :zero) + :one".
        for assignment in re.split(r",\s*(?=[#\w]+\s*=)", set_part):
            field, expr = [s.strip() for s in assignment.split("=", 1)]
            field = names.get(field, field)
            increment = re.match(r"if_not_exists\((\w+), (:\w+)\) \+ (:\w+)", expr)
            if increment:
                base = item.get(increment.group(1), values[increment.group(2)])
                item[field] = base + values[increment.group(3)]
            else:
                item[field] = deepcopy(values[expr])

        for field in [f.strip() for f in remove_part.split(",") if f.strip()]:
            item.pop(names.get(field, field), None)
        return {}

    def scan(self, FilterExpression=None, ExpressionAttributeValues=None, ExclusiveStartKey=None):
        self.calls["scan"] += 1
        wanted = (ExpressionAttributeValues or {}).get(":t")
        items = [
            deepcopy(i)
            for i in self.items.values()
            if not FilterExpression or i.get("itemType") == wanted
        ]
        return {"Items": items}


FAKE_TABLE = FakeTable()

fake_boto3 = types.ModuleType("boto3")
fake_boto3.resource = lambda *a, **kw: types.SimpleNamespace(Table=lambda name: FAKE_TABLE)
sys.modules["boto3"] = fake_boto3

fake_exceptions = types.ModuleType("botocore.exceptions")
fake_exceptions.ClientError = FakeClientError
fake_botocore = types.ModuleType("botocore")
fake_botocore.exceptions = fake_exceptions
sys.modules["botocore"] = fake_botocore
sys.modules["botocore.exceptions"] = fake_exceptions

import device_handler as dh  # noqa: E402


# ------------------------------------------------------------- Werkzeug

def event(route, body=None, path_params=None, headers=None):
    method, path = route.split(" ", 1)
    return {
        "routeKey": route,
        "rawPath": path,
        "requestContext": {"http": {"method": method}},
        "pathParameters": path_params or {},
        "headers": headers or {},
        "body": json.dumps(body) if body is not None else None,
    }


def call(route, **kwargs):
    response = dh.lambda_handler(event(route, **kwargs), None)
    return response["statusCode"], json.loads(response["body"])


def enroll_body(mac, secret=None, ts=None, nonce=None):
    secret = secret if secret is not None else os.environ["ENROLL_SECRET"]
    ts = ts if ts is not None else int(time.time())
    # Zufall, nicht Zeit: time.time_ns() hat unter Windows ~15 ms Aufloesung,
    # zwei schnell aufeinanderfolgende Aufrufe bekaemen dieselbe Nonce und
    # liefen in den Replay-Schutz.
    nonce = nonce or secrets.token_hex(16)
    canonical = dh.canonical_mac(mac)
    signature = hmac.new(
        secret.encode(), (canonical + "|" + str(ts) + "|" + nonce).encode(), hashlib.sha256
    ).hexdigest()
    return {"mac": mac, "hostname": "display-test", "model": "VM",
            "ts": ts, "nonce": nonce, "hmac": signature}


RESULTS = []


def check(name, condition, detail=""):
    RESULTS.append((name, bool(condition), detail))
    mark = "OK  " if condition else "FEHL"
    print("  [" + mark + "] " + name + ("   " + detail if detail and not condition else ""))


# ---------------------------------------------------------------- Tests

print("\n=== 1 Enrollment =========================================")

MAC_A = "dc:a6:32:11:22:33"
status, first = call("POST /enroll", body=enroll_body(MAC_A))
check("Erstes Enrollment liefert 200", status == 200, str(first))
check("Token wird zurueckgegeben", len(first.get("token", "")) > 30)
check("deviceId ist aus der MAC abgeleitet",
      first["deviceId"] == dh.device_id_from_mac("dca632112233"))
check("Ohne Zuweisung ist roomId leer", first.get("roomId") is None)
check("Token liegt nur als Hash in der Tabelle",
      all("token" not in k for k in FAKE_TABLE.items[first["deviceId"]] if k != "tokenHash"))

DEVICE_A = first["deviceId"]
TOKEN_A = first["token"]

status, again = call("POST /enroll", body=enroll_body(MAC_A))
check("Re-Enrollment ist idempotent (gleiche deviceId)",
      status == 200 and again["deviceId"] == DEVICE_A)
check("Re-Enrollment wird als solches markiert", again.get("reEnrollment") is True)
check("Re-Enrollment rotiert das Token", again["token"] != TOKEN_A)
TOKEN_A = again["token"]

status, body = call("POST /enroll", body=enroll_body(MAC_A, secret="falsches-secret"))
check("Falsches Secret -> 401", status == 401, str(body))

replay = enroll_body("aa:bb:cc:dd:ee:01")
call("POST /enroll", body=replay)
status, body = call("POST /enroll", body=replay)
check("Wiederholter Request (Replay) -> 409", status == 409, str(body))

status, body = call("POST /enroll", body=enroll_body(MAC_A, ts=int(time.time()) - 3600))
check("Zeitversatz > 300s -> 403", status == 403, str(body))

status, body = call("POST /enroll", body=enroll_body("nicht-eine-mac"))
check("Ungueltige MAC -> 400", status == 400, str(body))

status, body = call("POST /enroll", body={"mac": MAC_A, "ts": int(time.time()),
                                          "nonce": "x" * 24, "hmac": "00"})
check("Fehlendes/falsches HMAC -> 401", status == 401, str(body))


print("\n=== 2 Config =============================================")

auth_a = {"Authorization": "Bearer " + TOKEN_A}

status, cfg = call("GET /config/{deviceId}", path_params={"deviceId": DEVICE_A}, headers=auth_a)
check("Config mit gueltigem Token -> 200", status == 200, str(cfg))
check("configVersion ist gesetzt", len(cfg.get("configVersion", "")) == 12)
check("Ohne Raum keine displayUrl", cfg.get("displayUrl") is None)
VERSION_UNASSIGNED = cfg["configVersion"]

status, body = call("GET /config/{deviceId}", path_params={"deviceId": DEVICE_A},
                    headers={"Authorization": "Bearer falsch"})
check("Falsches Token -> 401", status == 401, str(body))

status, body = call("GET /config/{deviceId}", path_params={"deviceId": DEVICE_A})
check("Ohne Authorization-Header -> 401", status == 401, str(body))

status, body = call("GET /config/{deviceId}", path_params={"deviceId": "d-000000000000"},
                    headers=auth_a)
check("Unbekanntes Geraet -> 404", status == 404, str(body))


print("\n=== 3 Admin: Zuweisung ===================================")

admin = {"X-Admin-Key": os.environ["ADMIN_KEY"]}

status, body = call("POST /devices/{deviceId}/assign", path_params={"deviceId": DEVICE_A},
                    body={"roomId": "201"})
check("Assign ohne Admin-Key -> 401", status == 401, str(body))

status, body = call("POST /devices/{deviceId}/assign", path_params={"deviceId": DEVICE_A},
                    body={"roomId": "201"}, headers=admin)
check("Assign mit Admin-Key -> 200", status == 200, str(body))

status, cfg = call("GET /config/{deviceId}", path_params={"deviceId": DEVICE_A}, headers=auth_a)
check("Raumzuweisung wirkt ohne Geraetezugriff", cfg.get("roomId") == "201")
check("displayUrl zeigt auf den Raum", cfg.get("displayUrl", "").endswith("?room=201"))
check("Zuweisung erzeugt eine neue configVersion",
      cfg["configVersion"] != VERSION_UNASSIGNED)
VERSION_ASSIGNED = cfg["configVersion"]


print("\n=== 4 Checkin und Compliance =============================")

status, body = call("POST /checkin", headers=auth_a, body={
    "deviceId": DEVICE_A, "configVersion": VERSION_ASSIGNED, "agentVersion": "0.1.0",
    "ansible": {"ok": 24, "changed": 0, "failed": 0, "duration": 12.4},
    "kioskActive": True})
check("Sauberer Lauf -> COMPLIANT", body.get("compliance") == "COMPLIANT", str(body))

status, body = call("POST /checkin", headers=auth_a, body={
    "deviceId": DEVICE_A, "configVersion": VERSION_ASSIGNED,
    "ansible": {"ok": 22, "changed": 2, "failed": 0}, "changedTasks": ["kiosk url"]})
check("changed > 0 -> DRIFT (erkannt und korrigiert)",
      body.get("compliance") == "DRIFT", str(body))

status, body = call("POST /checkin", headers=auth_a, body={
    "deviceId": DEVICE_A, "configVersion": VERSION_ASSIGNED,
    "ansible": {"ok": 20, "changed": 1, "failed": 1}})
check("failed > 0 -> FAILED", body.get("compliance") == "FAILED", str(body))

status, body = call("POST /checkin", headers=auth_a, body={
    "deviceId": DEVICE_A, "configVersion": "veraltet1234",
    "ansible": {"ok": 24, "changed": 0, "failed": 0}})
check("Alte configVersion -> PENDING_CONFIG",
      body.get("compliance") == "PENDING_CONFIG", str(body))
check("Antwort nennt die Soll-Version",
      body.get("desiredConfigVersion") == VERSION_ASSIGNED, str(body))
check("Checkin ist kein Push-Kanal", body.get("action") == "none")


print("\n=== 5 Flottenuebersicht ==================================")

call("POST /enroll", body=enroll_body("aa:bb:cc:00:00:02"))
status, fleet = call("GET /devices", headers=admin)
check("Flottenliste -> 200", status == 200)
check("Nonces und Settings tauchen nicht als Geraete auf",
      all(d["deviceId"].startswith("d-") for d in fleet["devices"]), str(fleet["count"]))
check("tokenHash wird nicht ausgeliefert",
      all("tokenHash" not in d for d in fleet["devices"]))
check("Soll-Version steht pro Geraet in der Liste",
      all("desiredConfigVersion" in d for d in fleet["devices"]))
check("Geraet ohne Checkin gilt als STALE",
      any(d.get("compliance") == "STALE" for d in fleet["devices"]))


print("\n=== 6 Zentrale Aenderung =================================")

status, body = call("POST /settings", headers=admin, body={"kiosk": {"browser": "cog",
                                                                    "rotate": 90,
                                                                    "refreshSeconds": 30}})
check("Settings aendern -> 200", status == 200, str(body))
status, cfg = call("GET /config/{deviceId}", path_params={"deviceId": DEVICE_A}, headers=auth_a)
check("Globale Aenderung erreicht das Geraet", cfg["kiosk"]["rotate"] == 90)
check("Globale Aenderung erzeugt neue configVersion",
      cfg["configVersion"] != VERSION_ASSIGNED)

status, body = call("POST /settings", headers=admin, body={"gibtsNicht": 1})
check("Unbekannte Einstellung -> 400", status == 400, str(body))


print("\n=== 7 Lifecycle: Widerruf ================================")

status, body = call("POST /devices/{deviceId}/revoke", path_params={"deviceId": DEVICE_A},
                    headers=admin)
check("Revoke -> 200", status == 200, str(body))

status, body = call("GET /config/{deviceId}", path_params={"deviceId": DEVICE_A}, headers=auth_a)
check("Widerrufenes Geraet bekommt keine Config mehr", status == 401 or status == 403, str(body))

status, body = call("POST /enroll", body=enroll_body(MAC_A))
check("Widerrufenes Geraet darf sich nicht neu anmelden", status == 403, str(body))


print("\n=== 8 Router =============================================")

status, body = call("GET /gibtsnicht")
check("Unbekannte Route -> 404", status == 404, str(body))
status, _ = call("OPTIONS /enroll")
check("CORS-Preflight -> 200", status == 200)


# --------------------------------------------------------------- Fazit

passed = sum(1 for _, ok, _ in RESULTS if ok)
total = len(RESULTS)
print("\n" + "=" * 58)
print("  " + str(passed) + " / " + str(total) + " Pruefungen bestanden")
print("  DynamoDB-Operationen: " + json.dumps(FAKE_TABLE.calls))
print("=" * 58 + "\n")

if passed != total:
    for name, ok, detail in RESULTS:
        if not ok:
            print("FEHLGESCHLAGEN: " + name + "  " + detail)
    sys.exit(1)
