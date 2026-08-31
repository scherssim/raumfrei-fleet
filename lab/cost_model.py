#!/usr/bin/env python3
"""cost_model.py - Messreihe M3: Intervall gerechnet.

Rechnet die Backend-Kosten fuer die Kreuzung

    Intervall {5 min, 15 min, Lektionsende, 1x/Tag}
  x Flotte    {20, 200, 2000 Geraete}

und schreibt das Ergebnis nach results/cost_model.csv.

Die Frage dahinter ist nicht "was kostet AWS", sondern: *welches Intervall
ist zu rechtfertigen*. Ein Tuerschild muss genau dann aktuell sein, wenn die
naechste Lektion beginnt - jeder Lauf dazwischen kostet Geld und bringt
nichts. Das Skript macht diesen Unterschied in Franken sichtbar.

Zwei Zahlen sind Annahmen und muessen vor der Abgabe durch Messwerte ersetzt
werden (beide stehen in CloudWatch, Metrik "Duration" je Lambda):

    --ms-config    Laufzeit von GET  /config/{deviceId}
    --ms-checkin   Laufzeit von POST /checkin

Alles andere ist entweder gezaehlt (test_local.py zaehlt die DynamoDB-
Operationen mit) oder Listenpreis.

Aufruf:

    python cost_model.py                 # Tabelle + CSV
    python cost_model.py --calculator    # zusaetzlich die Eingabewerte fuer
                                         # den AWS Pricing Calculator
    python cost_model.py --ms-config 41 --ms-checkin 63 --no-free-tier
"""

import argparse
import csv
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")

# --------------------------------------------------------------------------
# Preise - Region eu-central-1 (Frankfurt), Listenpreis in USD.
#
# ACHTUNG: Diese Werte sind aus dem Gedaechtnis eingetragen und vor der
# Abgabe gegen die Preisseite zu pruefen. Genau dafuer ist "--calculator"
# da: der AWS Pricing Calculator rechnet dieselben Mengen mit den echten
# Preisen und dient als zweiter, unabhaengiger Beleg (so verlangt es M3).
# Stimmt ein Wert nicht, hier korrigieren - die Rechnung bleibt gleich.
# --------------------------------------------------------------------------
PREISE = {
    "lambda_pro_request": 0.20 / 1_000_000,      # USD je Invocation
    "lambda_pro_gb_sekunde": 0.0000166667,       # USD je GB-s
    "apigw_http_pro_request": 1.11 / 1_000_000,  # USD je Request (HTTP API)
    "ddb_pro_rru": 0.2827 / 1_000_000,           # USD je Read Request Unit
    "ddb_pro_wru": 1.4135 / 1_000_000,           # USD je Write Request Unit
    "ddb_speicher_pro_gb_monat": 0.306,
    "usd_pro_chf": 1.0,  # 1:1 gerechnet; Wechselkurs im Bericht benennen
}

QUELLEN = [
    "https://aws.amazon.com/lambda/pricing/",
    "https://aws.amazon.com/api-gateway/pricing/",
    "https://aws.amazon.com/dynamodb/pricing/on-demand/",
]

# Dauerhaft kostenfreies Kontingent (nicht die 12-Monats-Stufe).
FREE_TIER = {
    "lambda_requests": 1_000_000,
    "lambda_gb_sekunden": 400_000,
    "ddb_speicher_gb": 25.0,
}

LAMBDA_MB = 128  # so deployt deploy_devices.ps1

# --------------------------------------------------------------------------
# Was ein Agent-Lauf im Backend ausloest.
#
# Gezaehlt im Handler (backend/device_handler.py), belegt durch die
# Operationszaehler in backend/test_local.py:
#
#   GET  /config    authenticate -> get_device      1 get_item
#                   get_settings                    1 get_item
#   POST /checkin   authenticate -> get_device      1 get_item
#                   get_settings                    1 get_item
#                   Bericht schreiben               1 update_item
#
# get_item ist eventually consistent und kostet fuer Items bis 4 KB eine
# halbe RRU. Der Schreibvorgang legt den letzten Bericht mit ins Item; mit
# rund 1,5 KB sind das 2 WRU (aufgerundet je angefangenem KB).
# --------------------------------------------------------------------------
RRU_PRO_GET_ITEM = 0.5
ITEM_KB_NACH_CHECKIN = 1.5
WRU_PRO_CHECKIN = math.ceil(ITEM_KB_NACH_CHECKIN)

OPS = {
    "config": {"lambda": 1, "apigw": 1, "get_item": 2, "update_item": 0},
    "checkin": {"lambda": 1, "apigw": 1, "get_item": 2, "update_item": 1},
}

# --------------------------------------------------------------------------
# Intervalle. Laeufe pro Geraet und Monat (30 Tage).
#
# "Lektionsende" ist der gebaute Takt: acht Laeufe an Schultagen, dazu ein
# Lauf nach dem Booten. 8 x 21,7 Werktage = rund 173 Laeufe - dieselbe Zahl,
# die im Journal an Tag 2 steht.
# --------------------------------------------------------------------------
WERKTAGE_PRO_MONAT = 30 * 5 / 7

INTERVALLE = [
    ("5 min",         288 * 30,                    "rund um die Uhr alle 5 Minuten"),
    ("15 min",         96 * 30,                    "rund um die Uhr alle 15 Minuten"),
    ("Lektionsende",   round(8 * WERKTAGE_PRO_MONAT), "8 Laeufe an Schultagen - der gebaute Takt"),
    ("1x taeglich",     1 * 30,                    "einmal pro Nacht"),
]

FLOTTEN = [20, 200, 2000]


def kosten(laeufe_pro_geraet, geraete, ms_config, ms_checkin, free_tier):
    """Monatskosten fuer eine Kombination. Gibt ein dict zurueck."""
    laeufe = laeufe_pro_geraet * geraete

    lambda_requests = laeufe * (OPS["config"]["lambda"] + OPS["checkin"]["lambda"])
    apigw_requests = laeufe * (OPS["config"]["apigw"] + OPS["checkin"]["apigw"])
    rru = laeufe * (OPS["config"]["get_item"] + OPS["checkin"]["get_item"]) * RRU_PRO_GET_ITEM
    wru = laeufe * OPS["checkin"]["update_item"] * WRU_PRO_CHECKIN

    gb = LAMBDA_MB / 1024.0
    gb_sekunden = laeufe * gb * ((ms_config + ms_checkin) / 1000.0)

    # Speicher: ein Item je Geraet plus die Nonces, die per TTL nach 300 s
    # wieder verschwinden. Beides ist im zweistelligen MB-Bereich und liegt
    # in jeder Variante unter dem kostenfreien Kontingent - trotzdem
    # ausgewiesen, damit die Rechnung vollstaendig ist.
    speicher_gb = geraete * ITEM_KB_NACH_CHECKIN / 1024.0 / 1024.0

    if free_tier:
        abrechenbare_requests = max(0, lambda_requests - FREE_TIER["lambda_requests"])
        abrechenbare_gb_s = max(0.0, gb_sekunden - FREE_TIER["lambda_gb_sekunden"])
        abrechenbarer_speicher = max(0.0, speicher_gb - FREE_TIER["ddb_speicher_gb"])
    else:
        abrechenbare_requests = lambda_requests
        abrechenbare_gb_s = gb_sekunden
        abrechenbarer_speicher = speicher_gb

    p = PREISE
    posten = {
        "Lambda Requests": abrechenbare_requests * p["lambda_pro_request"],
        "Lambda Laufzeit": abrechenbare_gb_s * p["lambda_pro_gb_sekunde"],
        "API Gateway": apigw_requests * p["apigw_http_pro_request"],
        "DynamoDB Lesen": rru * p["ddb_pro_rru"],
        "DynamoDB Schreiben": wru * p["ddb_pro_wru"],
        "DynamoDB Speicher": abrechenbarer_speicher * p["ddb_speicher_pro_gb_monat"],
    }
    total = sum(posten.values())

    return {
        "geraete": geraete,
        "laeufe_pro_geraet": laeufe_pro_geraet,
        "laeufe": laeufe,
        "requests": apigw_requests,
        "lambda_requests": lambda_requests,
        "gb_sekunden": gb_sekunden,
        "rru": rru,
        "wru": wru,
        "speicher_gb": speicher_gb,
        "posten": posten,
        "usd_monat": total,
        "usd_pro_geraet": total / geraete,
    }


def tabelle(zeilen, ms_config, ms_checkin, free_tier):
    breite = 92
    print("=" * breite)
    print("M3 - KOSTENMODELL, gerechnet   (Region eu-central-1, Lambda %d MB)" % LAMBDA_MB)
    print("=" * breite)
    print("Laufzeit je Aufruf: /config %d ms, /checkin %d ms%s"
          % (ms_config, ms_checkin,
             "   << ANNAHME, durch CloudWatch-Messwerte ersetzen" if not zeilen[0].get("gemessen") else ""))
    print("Kostenfreies Kontingent: %s" % ("beruecksichtigt" if free_tier else "NICHT beruecksichtigt"))
    print()
    kopf = "%-14s %7s %9s %12s %12s %12s" % (
        "Intervall", "Geraete", "Laeufe/Ge", "Requests/Mt", "USD/Monat", "USD/Ge/Mt")
    print(kopf)
    print("-" * breite)
    letztes_intervall = None
    for z in zeilen:
        if letztes_intervall is not None and z["intervall"] != letztes_intervall:
            print("-" * breite)
        letztes_intervall = z["intervall"]
        print("%-14s %7d %9d %12s %12.4f %12.5f" % (
            z["intervall"] if z["geraete"] == FLOTTEN[0] else "",
            z["geraete"], z["laeufe_pro_geraet"], "{:,}".format(z["requests"]),
            z["usd_monat"], z["usd_pro_geraet"]))
    print("=" * breite)


def aufschluesselung(zeile):
    print()
    print("Aufschluesselung fuer %s / %d Geraete:" % (zeile["intervall"], zeile["geraete"]))
    for name, betrag in zeile["posten"].items():
        print("    %-20s %10.5f USD" % (name, betrag))
    print("    %-20s %10.5f USD" % ("SUMME", zeile["usd_monat"]))


def calculator(zeilen):
    """Die Mengen, die im AWS Pricing Calculator einzutragen sind.

    M3 verlangt die Eigenrechnung UND zwei Estimates aus dem Calculator.
    Damit beide dasselbe rechnen, muessen dieselben Mengen hinein - hier
    stehen sie in genau den Einheiten, die der Calculator abfragt.
    """
    print()
    print("=" * 92)
    print("EINGABEWERTE FUER DEN AWS PRICING CALCULATOR")
    print("=" * 92)
    print("Zwei Estimates anlegen (so verlangt es M3) und den Share-Link")
    print("in docs/nachweise/ ablegen:")
    print("  Estimate A: Lektionsende / 20 Geraete   - der gebaute Zustand")
    print("  Estimate B: 5 min / 2000 Geraete        - die Gegenprobe")
    print()
    for z in zeilen:
        if not ((z["intervall"] == "Lektionsende" and z["geraete"] == 20)
                or (z["intervall"] == "5 min" and z["geraete"] == 2000)):
            continue
        print("-" * 92)
        print("%s / %d Geraete" % (z["intervall"], z["geraete"]))
        print("  AWS Lambda")
        print("    Anzahl Requests je Monat . . . . . %s" % "{:,}".format(z["lambda_requests"]))
        print("    Zugewiesener Speicher  . . . . . . %d MB" % LAMBDA_MB)
        print("    Rechenzeit gesamt  . . . . . . . . %.1f GB-Sekunden" % z["gb_sekunden"])
        print("  Amazon API Gateway (HTTP API)")
        print("    Requests je Monat  . . . . . . . . %s" % "{:,}".format(z["requests"]))
        print("  Amazon DynamoDB (On-Demand)")
        print("    Read Request Units je Monat  . . . %s" % "{:,.0f}".format(z["rru"]))
        print("    Write Request Units je Monat . . . %s" % "{:,.0f}".format(z["wru"]))
        print("    Datenspeicher  . . . . . . . . . . %.4f GB" % z["speicher_gb"])
    print("-" * 92)


def main():
    ap = argparse.ArgumentParser(description="M3 - Kostenmodell rechnen")
    ap.add_argument("--ms-config", type=float, default=45.0,
                    help="gemessene Laufzeit von GET /config in ms (Vorgabe: Annahme 45)")
    ap.add_argument("--ms-checkin", type=float, default=70.0,
                    help="gemessene Laufzeit von POST /checkin in ms (Vorgabe: Annahme 70)")
    ap.add_argument("--no-free-tier", action="store_true",
                    help="ohne das dauerhaft kostenfreie Kontingent rechnen")
    ap.add_argument("--calculator", action="store_true",
                    help="Eingabewerte fuer den AWS Pricing Calculator ausgeben")
    ap.add_argument("--csv", default=os.path.join(RESULTS, "cost_model.csv"))
    args = ap.parse_args()

    free_tier = not args.no_free_tier

    zeilen = []
    for name, laeufe, _ in INTERVALLE:
        for geraete in FLOTTEN:
            z = kosten(laeufe, geraete, args.ms_config, args.ms_checkin, free_tier)
            z["intervall"] = name
            zeilen.append(z)

    tabelle(zeilen, args.ms_config, args.ms_checkin, free_tier)

    # Die beiden Zeilen, um die es im Bericht geht.
    for z in zeilen:
        if z["intervall"] == "Lektionsende" and z["geraete"] == 20:
            aufschluesselung(z)
        if z["intervall"] == "5 min" and z["geraete"] == 2000:
            aufschluesselung(z)

    # Das Argument in einem Satz.
    lekt = next(z for z in zeilen if z["intervall"] == "Lektionsende" and z["geraete"] == 20)
    fuenf = next(z for z in zeilen if z["intervall"] == "5 min" and z["geraete"] == 20)
    print()
    print("Kernaussage: bei 20 Geraeten kostet der 5-Minuten-Takt das %.1f-fache"
          % (fuenf["requests"] / float(lekt["requests"])))
    print("des gebauten Takts an Requests - fuer eine Anzeige, die sich nur")
    print("zu den Lektionsenden aendert.")

    os.makedirs(RESULTS, exist_ok=True)
    with open(args.csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["intervall", "geraete", "laeufe_pro_geraet_monat",
                    "requests_monat", "lambda_gb_sekunden", "ddb_rru", "ddb_wru",
                    "usd_monat", "usd_pro_geraet_monat", "free_tier",
                    "ms_config", "ms_checkin"])
        for z in zeilen:
            w.writerow([z["intervall"], z["geraete"], z["laeufe_pro_geraet"],
                        z["requests"], round(z["gb_sekunden"], 2),
                        int(z["rru"]), int(z["wru"]),
                        round(z["usd_monat"], 6), round(z["usd_pro_geraet"], 8),
                        "ja" if free_tier else "nein",
                        args.ms_config, args.ms_checkin])
    print()
    print("geschrieben: %s" % args.csv)

    if args.calculator:
        calculator(zeilen)

    print()
    print("Preisquellen (vor der Abgabe pruefen):")
    for q in QUELLEN:
        print("  " + q)


if __name__ == "__main__":
    main()
