"""
seed_rooms.py – DynamoDB-Tabelle "RaumFrei" mit Schulzimmern befüllen.

Übernommen aus der Transferarbeit Cloud & Serverless (SS26). EINZIGE Änderung
gegenüber dem Original: die Region.

Das Original hatte REGION = "us-east-1" fest verdrahtet – die Region des
AWS-Academy-Kontos, das inzwischen tot ist. Hier zieht die Flotte nach
eu-central-1 um; ohne diese Zeile schriebe das Skript stumm in eine Region,
in der die Tabelle gar nicht existiert, und liefe dabei ohne Fehlermeldung
in ein ResourceNotFound.

Voraussetzung:
  - AWS CLI konfiguriert, Profil mit Schreibrechten auf die Tabelle
  - Tabelle "RaumFrei" existiert (wird von deploy_rooms.ps1 erstellt)

Ausführen:
  python seed_rooms.py
  AWS_DEFAULT_REGION=eu-central-1 python seed_rooms.py   # überschreibt
"""

import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_DEFAULT_REGION", "eu-central-1")
TABLE_NAME = os.environ.get("TABLE_NAME", "RaumFrei")

ROOMS = [
    {
        "roomId": "101",
        "name": "Zimmer 101",
        "floor": "Erdgeschoss",
        "capacity": 30,
        "equipment": "Beamer, Whiteboard",
        "status": "FREE",
    },
    {
        "roomId": "102",
        "name": "Zimmer 102",
        "floor": "Erdgeschoss",
        "capacity": 28,
        "equipment": "Whiteboard",
        "status": "FREE",
    },
    {
        "roomId": "201",
        "name": "Zimmer 201",
        "floor": "1. Obergeschoss",
        "capacity": 32,
        "equipment": "Beamer, Laptop-Anschluss",
        "status": "FREE",
    },
    {
        "roomId": "202",
        "name": "Zimmer 202",
        "floor": "1. Obergeschoss",
        "capacity": 25,
        "equipment": "Whiteboard, TV",
        "status": "FREE",
    },
    {
        "roomId": "301",
        "name": "Zimmer 301",
        "floor": "2. Obergeschoss",
        "capacity": 20,
        "equipment": "Beamer",
        "status": "FREE",
    },
    {
        "roomId": "IT-LABOR",
        "name": "Labor IT",
        "floor": "2. Obergeschoss",
        "capacity": 16,
        "equipment": "16× PC, Beamer",
        "status": "FREE",
    },
    {
        "roomId": "AULA",
        "name": "Aula",
        "floor": "Erdgeschoss",
        "capacity": 120,
        "equipment": "Bühne, Beamer, Mikrofon",
        "status": "FREE",
    },
    {
        "roomId": "SITZUNG-OG1",
        "name": "Sitzungszimmer OG 1",
        "floor": "1. Obergeschoss",
        "capacity": 10,
        "equipment": "TV, Whiteboard",
        "status": "FREE",
    },
]


def main():
    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    table = dynamodb.Table(TABLE_NAME)

    print(f"Befülle Tabelle '{TABLE_NAME}' mit {len(ROOMS)} Zimmern...\n")

    for room in ROOMS:
        try:
            table.put_item(
                Item=room,
                ConditionExpression="attribute_not_exists(roomId)",
            )
            print(f"  ✓ {room['roomId']:15s} – {room['name']}")
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                print(f"  ~ {room['roomId']:15s} – existiert bereits, übersprungen")
            else:
                print(f"  ✗ {room['roomId']:15s} – Fehler: {e}")

    print(f"\nFertig. {len(ROOMS)} Zimmer verarbeitet.")


if __name__ == "__main__":
    main()
