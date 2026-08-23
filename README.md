# raumfrei-fleet

Raumdisplays für die Webanwendung **RaumFrei** zentral verwalten:
Zero-Touch-Enrollment, Pull-basiertes Config-Management und Compliance-Reporting
für Clients hinter NAT.

Transferbericht im Modul **Client Management**, HF Plattformentwicklung, TEKO Olten,
Sommersemester 2026 · Einzelarbeit Simon Scherer · Dozent Mario Iseli ·
Abgabe **Mo 07.09.2026**.

---

## Worum es geht

Im Modul Cloud Serverless ist *RaumFrei* entstanden — ein Raumbuchungssystem auf AWS,
in dem Lehrpersonen Lektionen buchen. Die naheliegende Fortsetzung ist ein Display
neben jedem Schulzimmer, das den Belegungsplan dieses Raums zeigt.

Damit entsteht genau das Problem, um das es in diesem Modul geht: eine Flotte
gleichartiger Clients, verteilt über Stockwerke und Standorte, ohne IT vor Ort,
im Schulnetz hinter NAT — also ohne öffentliche Adresse und von aussen nicht erreichbar.

Das Image bringt nur zwei Dinge mit: die Backend-URL und ein gemeinsames
Enrollment-Secret. Alles andere holt sich das Gerät selbst.

## Die Dreiteilung

| Was | Wo | Warum dort |
|---|---|---|
| Flottenweiter Soll-Zustand (Pakete, Units, Kiosk-Rolle, `display.html`) | **dieses Git-Repo** | versioniert, reviewbar, ohne Auth klonbar — enthält keine Geheimnisse |
| Geräteidentität, Token, Raumzuweisung, Status | **Backend / DynamoDB** | pro Gerät verschieden, vertraulich, muss widerrufbar sein |
| Enrollment-Secret + Backend-URL | **Image** | die einzigen zwei Dinge, die das Gerät mitbringen darf |

Deshalb darf dieses Repo öffentlich sein.

## Ablauf auf dem Gerät

```
boot
 └─ cloud-init ──► Pakete, /etc/raumfrei/agent.env, systemd-Units
     └─ raumfrei-enroll   POST /enroll   (HMAC über mac|ts|nonce)
         └─ raumfrei-agent
             ├─ GET  /config/{deviceId}   → /etc/raumfrei/desired.json
             ├─ ansible-pull -U <dieses Repo> site.yml
             └─ POST /checkin             → Compliance-Meldung
                 └─ raumfrei-agent.timer  (getaktet auf die Lektionsenden)
```

Das Gerät **holt** — es empfängt nie. Das ist keine Bequemlichkeit, sondern die
einzige Bauweise, die hinter NAT funktioniert, und dieselbe, die Intune, Jamf und
Puppet aus demselben Grund wählen.

## Verzeichnisse

| Pfad | Inhalt |
|---|---|
| `backend/` | Lambda `device_handler.py`, Deployment, IAM-Policies, Tests |
| `ansible/` | `site.yml` und die Rollen `base`, `agent`, `kiosk` — Einstiegspunkt für `ansible-pull` |
| `client/` | cloud-init, Enrollment- und Agent-Skript, systemd-Units, `display.html` |
| `lab/` | Flotten-Skripte, Drift-Injektion, Messreihen und Auswertungen |
| `docs/` | Nachweise und Grafiken für den Bericht |
| `journal/` | Arbeitsjournal |

## Backend lokal testen (ohne AWS)

```bash
cd backend
python test_local.py      # 44 Prüfungen, DynamoDB wird in-memory nachgebildet
```

## Backend deployen

```powershell
cd backend
.\deploy_devices.ps1      # eigenes AWS-Konto, eu-central-1
bash test_api.sh          # Smoke-Test gegen die deployte API
```

Secrets werden beim ersten Deploy erzeugt und in `backend/secrets.env` abgelegt —
diese Datei ist gitignored und bleibt lokal.

## API

| Route | Auth | Zweck |
|---|---|---|
| `POST /enroll` | HMAC über das Enrollment-Secret | Erstboot: Secret → Identität + Token |
| `GET /config/{deviceId}` | Bearer-Token | Soll-Zustand des Geräts |
| `POST /checkin` | Bearer-Token | Ist-Zustand melden |
| `GET /devices` | `X-Admin-Key` | Flottenübersicht mit Compliance |
| `POST /devices/{deviceId}/assign` | `X-Admin-Key` | Raum zuweisen |
| `POST /devices/{deviceId}/revoke` | `X-Admin-Key` | Token widerrufen |
| `POST /devices/{deviceId}/retire` | `X-Admin-Key` | Gerät ausmustern |
| `GET` / `POST /settings` | `X-Admin-Key` | flottenweiter Soll-Zustand |

`configVersion` ist der Hash des effektiven Soll-Zustands: jede Änderung — global
oder pro Gerät — erzeugt automatisch eine neue Version.

## Bewusst nicht in diesem Repo

Produktionsreife Sicherheit (Gerätezertifikate statt Token, Secret-Management, HA),
ein produktives UEM, Push-Betrieb, AD/GPO, Kubernetes, eine CMDB und die
Weiterentwicklung von RaumFrei selbst. Die Grenzen sind im Bericht benannt.
