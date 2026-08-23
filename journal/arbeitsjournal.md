# Arbeitsjournal — Simon Scherer

Transferbericht Client Management SS26 · Projekt `raumfrei-fleet`

> **Dieses Journal führe ich selbst.** Es ist laut Vorlage und
> Eigenständigkeitserklärung ein individuell verpflichtender Teil und wandert am
> Ende in den Anhang des Berichts. Richtwert: 10–20 Einträge.
>
> Format pro Eintrag: **was gemacht · was gelernt · was geblockt**.
> Die Zeilen unter «gemacht» sind Fakten aus dem Projektverlauf — «gelernt» und
> «geblockt» schreibe ich in eigenen Worten, sonst ist das Journal wertlos.

---

## 2026-08-23 · Tag 1 — Aufsetzen und Backend

**Gemacht**
- Idee von Mario abgenommen zurückerhalten; Scope steht damit fest.
- Umsetzungsplan erstellt: Lab bis So 30.08., danach eine Woche Bericht.
- Repo `raumfrei-fleet` angelegt, Struktur backend/ansible/client/lab/docs/journal.
- Backend-Lambda `device_handler.py` geschrieben: `/enroll` (HMAC über
  `mac|ts|nonce`, Nonce-Replay-Schutz per DynamoDB-TTL), `/config/{deviceId}`,
  `/checkin` mit Compliance-Bewertung, Admin-Routen für Zuweisung, Widerruf und
  Ausmusterung.
- Entscheid: `deviceId` deterministisch aus der MAC (`sha256(salt+mac)[:12]`) —
  damit ist Re-Enrollment idempotent, ohne GSI auf die MAC.
- Entscheid: `configVersion` ist der Hash des effektiven Soll-Zustands statt
  eines Zählers — jede Änderung erzeugt automatisch eine neue Version.
- `test_local.py` geschrieben: DynamoDB in-memory nachgebildet, 44 Prüfungen
  inklusive aller Fehlerfälle. Alle grün, ohne dass AWS im Spiel war.
- Deployment-Skript für eu-central-1 mit eigener IAM-Rolle (Least Privilege nur
  auf die `Devices`-Tabelle) statt der LabRole des AWS-Academy-Kontos.

**Gelernt**
- _(selbst ausfüllen — z. B. warum ein HMAC über die Nonce mehr bringt als das
  Secret einfach mitzuschicken, oder was der Hash-als-Version-Trick erspart)_

**Geblockt**
- _(selbst ausfüllen)_

---

<!-- Vorlage für die weiteren Einträge:

## 2026-08-__ · Tag _ — <Thema>

**Gemacht**
-

**Gelernt**
-

**Geblockt**
-

-->
