# Lab — vom leeren Hyper-V zur gemessenen Flotte

Alles, was für die Messreihen M1–M7 gebraucht wird. Die Reihenfolge unten ist
die Reihenfolge, in der es gemacht werden muss — Teil A einmal, Teil B pro
Türschild, Teil C für die Messungen.

| Werkzeug | Messreihe | läuft auf |
|---|---|---|
| `new-display-vm.ps1` | — (legt die VM an) | Windows-Host, **erhöht** |
| `measure_zerotouch.sh` | **M1** Zero Touch | dem Türschild |
| `inject_drift.sh` | **M4** Drift-Matrix | dem Türschild |
| `netpath_probe.sh` | **M5** Netzpfad | dem Türschild |
| `push_probe.sh` | **M7** Push-Gegenprobe | WSL / Incus-Host |
| `cost_model.py` | **M3** Kostenmodell | überall, braucht kein AWS |
| `fleet_up.sh` | **M2** Konvergenz, **M6** Skalierung | Incus-Host |

Ergebnisse landen in `results/` (kommt ins Repo), Rohdaten in `results/raw/`
(gitignored).

---

## Teil A · Einmalige Vorbereitung

### A1 · WSL-Ubuntu rüsten

Die Bildbearbeitung und der ISO-Bau brauchen Linux-Werkzeuge, die es unter
Windows nicht gibt. Die WSL-Ubuntu ist dafür da — nicht als Zielsystem,
sondern als Werkbank.

```bash
wsl -d Ubuntu
sudo apt update
sudo apt install -y qemu-utils cloud-image-utils genisoimage ansible
```

**Nicht `bash …` aus PowerShell aufrufen.** Das ist
`C:\Windows\System32\bash.exe` und startet die *Standard*-Distribution. Liegt
die auf etwas anderem als Ubuntu (hier zeitweise `kali-linux`), fehlen genau
diese Werkzeuge und `make-seed.sh` bricht mit «weder cloud-localds noch
genisoimage noch xorrisofs gefunden» ab — während `make-user-data.sh` klaglos
durchläuft, weil es nur `base64` und Python braucht. Erkennungsmerkmal ist der
Pfad `/mnt/c/...` in der Ausgabe: das ist WSL, nicht Git Bash.

Einmal dauerhaft geradeziehen:

```powershell
wsl --set-default Ubuntu     # Kali bleibt über `wsl -d kali-linux` erreichbar
wsl -l -v                    # der * muss bei Ubuntu stehen
```

Oder je Aufruf ohne Wechsel, aus PowerShell heraus:

```powershell
wsl -d Ubuntu --cd /mnt/c/Users/simon/Desktop/Neuer_Ordner/_Teko/_S6/Client_Management/TA/raumfrei-fleet -- bash lab/push_probe.sh
```

### A2 · Golden-Image bauen

**Wichtig: das Cloud-Image, nicht das Server-Installer-ISO.** Der Installer
(`ubuntu-24.04-live-server-amd64.iso`) will `autoinstall`, führt eine
Installation durch und braucht dafür Minuten — und genau diese Minuten würden
M1 dominieren, obwohl sie mit Zero Touch nichts zu tun haben. Das Cloud-Image
ist ein fertig installiertes System, das beim ersten Start nur noch
cloud-init ausführt. Das ist der Fall, den ein Türschild im Betrieb hat.

Weiter in der WSL-Ubuntu:

```bash
mkdir -p ~/raumfrei && cd ~/raumfrei

# 1 Cloud-Image holen (~600 MB)
wget https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img

# 2 Platte vergrößern - 2,2 GB reichen für cage, den Browser und apt nicht.
#   cloud-init lässt das Dateisystem beim ersten Boot selbst mitwachsen.
qemu-img resize ubuntu-24.04-server-cloudimg-amd64.img 20G

# 3 nach VHDX wandeln, direkt an den Ort, wo Hyper-V es erwartet
mkdir -p /mnt/c/HyperV/golden
qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic \
    ubuntu-24.04-server-cloudimg-amd64.img \
    /mnt/c/HyperV/golden/ubuntu-2404.vhdx
```

Das VHDX wird ab jetzt **nie wieder angefasst**. Jede VM bekommt eine
Differenzplatte darauf — das ist der Grund, warum ein M1-Lauf in Sekunden neu
aufgesetzt ist statt in Minuten.

### A3 · Prüfen

```powershell
Get-Item C:\HyperV\golden\ubuntu-2404.vhdx | Select-Object Name, Length
Get-VMSwitch | Select-Object Name, SwitchType
```

Es muss ein Switch da sein — im Normalfall `Default Switch` (NAT). Fehlt er,
in `new-display-vm.ps1` mit `-Switch <Name>` einen anderen angeben.

---

## Teil B · Ein Türschild starten

### B1 · user-data und Seed-ISO bauen

In der WSL-Ubuntu, im Repo:

```bash
cd /mnt/c/Users/simon/Desktop/Neuer_Ordner/_Teko/_S6/Client_Management/TA/raumfrei-fleet

bash client/cloud-init/make-user-data.sh \
     --hostname display-a --kiosk --lab-zugang <passwort>

bash client/cloud-init/make-seed.sh --hostname display-a
```

`--lab-zugang` legt den Benutzer `lab` mit Passwort an. **Nur fürs Lab:** ohne
ihn hat das Image überhaupt kein Konto — was im Betrieb genau richtig ist, für
`measure_zerotouch.sh` und `inject_drift.sh` aber nicht geht, denn die laufen
auf dem Gerät. Im Bericht unter «Grenzen des Aufbaus» benennen: die gemessenen
VMs tragen einen Zugang, den ein ausgeliefertes Gerät nicht hätte.

Beides sind Erzeugnisse und gitignored — die `user-data` trägt das
`ENROLL_SECRET` im Klartext.

### B2 · VM anlegen und starten

PowerShell **als Administrator** (Hyper-V-Cmdlets verlangen es; dauerhaft
alternativ: eigenen Benutzer in die lokale Gruppe *Hyper-V-Administratoren*
aufnehmen und einmal ab- und anmelden):

```powershell
cd C:\Users\simon\Desktop\Neuer_Ordner\_Teko\_S6\Client_Management\TA\raumfrei-fleet\lab
.\new-display-vm.ps1 -Name display-a
```

Das Skript legt Differenzplatte und VM an, hängt das Seed-ISO als zweites
Laufwerk ein, schaltet Secure Boot und automatische Prüfpunkte aus und
startet. **Die ausgegebene Startzeit ist der Nullpunkt für M1.**

Zusehen:

```powershell
vmconnect.exe localhost display-a
```

### B3 · Was ohne jeden Handgriff passieren muss

| ab Start | was |
|---|---|
| ~20–40 s | cloud-init schreibt `agent.env`, Skripte, Units; `apt` holt ansible |
| ~60–90 s | `raumfrei-enroll` meldet an → `/etc/raumfrei/device.json` |
| ~2–6 min | erster `ansible-pull`: `cage`, Browser, Anzeigeseite, Units |
| danach | `raumfrei-kiosk.service` startet, der Raumplan steht |

Bis das Gerät im Backend einem Raum zugewiesen ist, zeigt es «nicht
zugewiesen» — das ist richtig so. Zuweisen in `backend/fleet.html`, der
nächste Agent-Lauf (oder `systemctl start raumfrei-agent.service`) holt es ab.

### B4 · Wenn nichts erscheint

Anmelden als `lab`, dann in dieser Reihenfolge:

```bash
cloud-init status --long                    # ist der Erstboot überhaupt durch?
journalctl -b -u raumfrei-enroll.service    # 403 = Secret/Uhrzeit falsch
journalctl -b -u raumfrei-agent.service     # der Regelkreis
cat /var/lib/raumfrei/last-pull.log         # was Ansible gemacht hat
journalctl -b -u raumfrei-kiosk.service     # der Spike-Kandidat
ls -l /dev/dri/                             # sieht cage überhaupt einen Schirm?
```

Die vier wahrscheinlichsten Fälle:

1. **`/dev/dri/` ist leer.** Dann findet `cage` kein DRM-Gerät und startet
   nicht. In Hyper-V liefert das der Treiber `hyperv_drm`;
   `sudo modprobe hyperv_drm` und nachsehen. Bleibt es leer, bleibt der Weg
   über `WLR_BACKENDS=headless` nicht — ein Türschild ohne Bild ist keins.
   Dann ist das der Befund für den Bericht: cage in Hyper-V braucht
   hyperv_drm, sonst ist die VM als Türschild ungeeignet.
2. **cage startet, der Schirm bleibt schwarz.** Software-Rendering erzwingen:
   in `/etc/raumfrei/kiosk.env` `WLR_RENDERER=pixman` ergänzen und die Unit
   neu starten. In einer VM gibt es keine GPU-Beschleunigung.
3. **Enrollment scheitert mit 403.** Fast immer die Uhr: der HMAC deckt einen
   Zeitstempel ab, das Backend lässt 300 s Versatz zu. `timedatectl` prüfen.
4. **`ansible-pull` läuft nicht.** `apt` war beim Erstboot noch nicht fertig
   oder ohne Netz — `systemctl start raumfrei-agent.service` von Hand und den
   Fehler im Log lesen.

---

## Teil C · Messen

### M1 · Zero Touch (n = 5)

Auf der VM, nach dem Erstboot:

```bash
sudo bash /mnt/lab/measure_zerotouch.sh --lauf 1 --label display-a
```

Das Repo ist auf der VM nicht da. Einfachster Weg: die Datei in die VM
kopieren (`scp` von der WSL aus, oder in der VM
`curl -O https://raw.githubusercontent.com/scherssim/raumfrei-fleet/main/lab/measure_zerotouch.sh`).

Für den nächsten Lauf **auf dem Host**:

```powershell
.\new-display-vm.ps1 -Name display-a -Neu
```

Das wirft die Differenzplatte weg — der nächste Start ist wieder ein
Erstboot. Fünfmal, Lauf hochzählen. Danach `results/zerotouch.csv` vom Gerät
holen und die Läufe zusammenführen.

### M4 · Drift-Matrix

Auf der VM, nachdem sie einmal sauber COMPLIANT gemeldet hat:

```bash
sudo bash inject_drift.sh --fall alle
```

Vier Eingriffe, je gemessen: heilt es lokal (systemd, Sekunden) oder zentral
(nächster Pull)? Ergebnis in `results/drift.csv`.

### M5 · Netzpfad

```bash
sudo bash netpath_probe.sh
```

Teil a läuft durch, Teil b sperrt den API-Host und wartet bei der Anzeige auf
ENTER — **in dem Moment den Schirm fotografieren**, die Fusszeile muss
«Stand von HH:MM» zeigen. Das Skript räumt danach selbst auf.

### M7 · Push-Gegenprobe

In der WSL-Ubuntu (also von der zentralen Seite aus):

```bash
bash lab/push_probe.sh
```

Läuft die Probe im selben Netz wie die VM, sagt das Skript das dazu — der
tragende Befund ist dann Schritt 1: die einzige bekannte Adresse ist eine
private, die das Gerät selbst gemeldet hat.

### M3 · Kostenmodell

Braucht weder VM noch AWS, kann sofort laufen:

```powershell
python lab\cost_model.py --calculator
```

Zwei Dinge fehlen noch und müssen vor der Abgabe hinein:

* die **gemessenen** Lambda-Laufzeiten aus CloudWatch (Metrik *Duration* je
  Funktion) statt der Annahmen: `--ms-config 41 --ms-checkin 63`
* die **Listenpreise prüfen** — die Werte in `PREISE` sind eingetragen, aber
  nicht gegen die Preisseite verifiziert. `--calculator` gibt die Mengen aus,
  die in den AWS Pricing Calculator gehören; M3 verlangt zwei Estimates samt
  Share-Link als zweiten, unabhängigen Beleg.

### M2 / M6 · Flotte

Braucht einen Incus-Host. Der Rückfall aus der Idee gilt: **Zero Touch und
Drift an den Displays gehen vor dem 20er-Test.** Wenn die Zeit reicht:

```bash
bash client/cloud-init/make-user-data.sh --hostname agent --headless
bash lab/fleet_up.sh up --anzahl 20
bash lab/fleet_up.sh status
# jetzt zentral etwas ändern (Commit oder assign), dann sofort:
bash lab/fleet_up.sh konvergenz --minuten 60
bash lab/fleet_up.sh down
```

---

## Teil D · Noch offen im Konto

* **Budget-Alarm 5 CHF** — Vorlage liegt in `backend/budget/`, war laut Plan
  die erste Handlung im Konto und ist bis heute nicht gesetzt.
* **`backend/iam/deploy-policy.json`** ist geschrieben, aber keinem Permission
  Set angehängt.
