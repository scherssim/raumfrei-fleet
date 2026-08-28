import json
import os
import decimal
import boto3


class _DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, decimal.Decimal):
            return int(obj) if obj % 1 == 0 else float(obj)
        return super().default(obj)

# ============================================================
# DynamoDB Client initialisieren
# Tabellenname kommt aus der Environment Variable TABLE_NAME
# (Fallback "RaumFrei"), damit der Code nicht an einen
# fixen Tabellennamen gebunden ist.
# Partition Key: roomId (String)
#
# Buchungsmodell:
#   Jedes Zimmer hat eine Map-Eigenschaft "bookings".
#   Schlüssel = "<Tag>#<Lektion>"  (z. B. "Mo#3", "Fr#8")
#   Wert      = Name der buchenden Person (z. B. "M. Müller")
#   Eine fehlende oder leere Map bedeutet: ganze Woche frei.
# ============================================================
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("TABLE_NAME", "RaumFrei"))

VALID_DAYS = {"Mo", "Di", "Mi", "Do", "Fr"}
VALID_LESSONS = {str(n) for n in range(1, 9)}  # "1".."8"


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        },
        "body": json.dumps(body, ensure_ascii=False, cls=_DecimalEncoder),
    }


def lambda_handler(event, context):
    print(json.dumps(event))
    method = event["requestContext"]["http"]["method"]
    path = event["rawPath"]

    if method == "OPTIONS":
        return respond(200, {})
    if path == "/rooms" and method == "GET":
        return get_rooms()
    if path == "/rooms/book" and method == "POST":
        return book_room(event)
    if path == "/rooms/release" and method == "POST":
        return release_room(event)

    return respond(404, {"message": f"Route nicht gefunden: {method} {path}"})


def _valid_cell(cell):
    """Prüft, ob ein Zellschlüssel die Form '<Tag>#<Lektion>' hat."""
    if not isinstance(cell, str) or "#" not in cell:
        return False
    day, lesson = cell.split("#", 1)
    return day in VALID_DAYS and lesson in VALID_LESSONS


def get_rooms():
    result = table.scan()
    rooms = sorted(result["Items"], key=lambda r: r.get("roomId", ""))
    # Sicherstellen, dass jedes Zimmer eine bookings-Map mitliefert,
    # damit das Frontend nie auf undefined prüfen muss.
    for room in rooms:
        if "bookings" not in room or not isinstance(room.get("bookings"), dict):
            room["bookings"] = {}
    return respond(200, rooms)


def book_room(event):
    body = json.loads(event["body"])
    room_id = body.get("roomId", "").strip()
    teacher_name = body.get("teacherName", "").strip()
    cells = body.get("cells", [])

    if not room_id or not teacher_name or not cells:
        return respond(400, {"message": "roomId, teacherName und cells sind erforderlich."})

    if not isinstance(cells, list) or not all(_valid_cell(c) for c in cells):
        return respond(400, {"message": "Ungültige Zellen. Format: '<Tag>#<Lektion>', z. B. 'Mo#3'."})

    # Doppelte Zellen aus der Anfrage entfernen.
    cells = list(dict.fromkeys(cells))

    result = table.get_item(Key={"roomId": room_id})
    room = result.get("Item")

    if not room:
        return respond(404, {"message": f"Zimmer '{room_id}' nicht gefunden."})

    bookings = room.get("bookings") if isinstance(room.get("bookings"), dict) else {}

    # Konflikte sammeln: bereits belegte Zellen.
    conflicts = {c: bookings[c] for c in cells if c in bookings}
    if conflicts:
        return respond(409, {
            "message": f"{len(conflicts)} der gewählten Zeiten sind bereits belegt.",
            "conflicts": conflicts,
        })

    # Alle gewählten Zellen belegen und die Map zurückschreiben.
    for c in cells:
        bookings[c] = teacher_name

    table.update_item(
        Key={"roomId": room_id},
        UpdateExpression="SET bookings = :b",
        ExpressionAttributeValues={":b": bookings},
    )

    return respond(200, {
        "message": f"{len(cells)} Buchung(en) für {teacher_name} in Zimmer '{room_id}' gespeichert.",
        "roomId": room_id,
        "teacherName": teacher_name,
        "cells": cells,
    })


def release_room(event):
    body = json.loads(event["body"])
    room_id = body.get("roomId", "").strip()
    cells = body.get("cells", [])

    if not room_id:
        return respond(400, {"message": "roomId ist erforderlich."})

    result = table.get_item(Key={"roomId": room_id})
    room = result.get("Item")

    if not room:
        return respond(404, {"message": f"Zimmer '{room_id}' nicht gefunden."})

    bookings = room.get("bookings") if isinstance(room.get("bookings"), dict) else {}

    if cells:
        # Nur die angegebenen Zellen freigeben.
        if not isinstance(cells, list) or not all(_valid_cell(c) for c in cells):
            return respond(400, {"message": "Ungültige Zellen. Format: '<Tag>#<Lektion>'."})
        removed = [c for c in cells if c in bookings]
        for c in removed:
            del bookings[c]
    else:
        # Ohne Zellen: ganze Woche dieses Zimmers freigeben.
        removed = list(bookings.keys())
        bookings = {}

    table.update_item(
        Key={"roomId": room_id},
        UpdateExpression="SET bookings = :b",
        ExpressionAttributeValues={":b": bookings},
    )

    return respond(200, {
        "message": f"{len(removed)} Buchung(en) in Zimmer '{room_id}' freigegeben.",
        "roomId": room_id,
        "cells": removed,
    })
