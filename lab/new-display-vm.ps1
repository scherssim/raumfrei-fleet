<#
.SYNOPSIS
    Legt eine Display-VM in Hyper-V an und startet sie - ohne einen einzigen
    Klick in der Hyper-V-Verwaltung.

.DESCRIPTION
    Das Tuerschild bekommt zwei Laufwerke:

      1. eine Differenzplatte auf das Golden-VHDX (Ubuntu-Cloud-Image)
      2. das NoCloud-Seed-ISO aus client/cloud-init/make-seed.sh

    Mehr braucht Zero Touch nicht. Alles Weitere - Enrollment, Ansible,
    Kiosk - passiert beim ersten Boot von selbst.

    Warum eine Differenzplatte statt einer Kopie: fuer M1 werden fuenf
    Erstboots gebraucht. Eine Differenzplatte ist in Sekunden angelegt und
    in Sekunden weggeworfen; das Golden-VHDX bleibt unberuehrt. Genau das
    macht "-Neu" - loeschen und frisch aufsetzen, so oft wie noetig.

    Zwei Einstellungen sind fuer die Messung wichtig und deshalb fest
    gesetzt: keine automatischen Pruefpunkte (sie verlaengern den Erstboot
    und stehen in keiner Messreihe) und Secure Boot aus (das Cloud-Image
    ist nicht mit einem von Microsoft anerkannten Schluessel signiert - mit
    Secure Boot bleibt der Schirm schwarz, ohne Fehlermeldung).

.NOTES
    Muss ERHOEHT laufen (Hyper-V-Cmdlets verlangen es).

.EXAMPLE
    .\new-display-vm.ps1 -Name display-a -Golden C:\HyperV\golden\ubuntu-2404.vhdx `
                         -SeedIso ..\client\cloud-init\display-a-seed.iso

.EXAMPLE
    .\new-display-vm.ps1 -Name display-a -Neu     # fuer den naechsten M1-Lauf
#>

[CmdletBinding()]
param(
    [string]$Name = "display-a",
    [string]$Golden = "C:\HyperV\golden\ubuntu-2404.vhdx",
    [string]$SeedIso = "",
    [string]$VmPfad = "C:\HyperV",
    [string]$Switch = "Default Switch",
    [int]$RamMB = 2048,
    [int]$Cpu = 2,
    [switch]$Neu,
    [switch]$NichtStarten
)

$ErrorActionPreference = "Stop"

function Schritt($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Hinweis($text) { Write-Host "    $text" -ForegroundColor DarkGray }
function Fehler($text)  { Write-Host "FEHLER: $text" -ForegroundColor Red }

# --- Vorbedingungen ---------------------------------------------------------
$istAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $istAdmin) {
    Fehler "Dieses Skript braucht erhoehte Rechte."
    Hinweis "PowerShell als Administrator oeffnen und erneut starten."
    exit 1
}

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Fehler "Das Hyper-V-PowerShell-Modul fehlt."
    Hinweis "Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All"
    exit 1
}

if (-not (Test-Path $Golden)) {
    Fehler "Golden-VHDX nicht gefunden: $Golden"
    Hinweis "Anleitung in lab/README.md, Abschnitt 1 (Cloud-Image holen und umwandeln)."
    exit 1
}

if (-not $SeedIso) {
    $SeedIso = Join-Path (Split-Path $PSScriptRoot -Parent) "client\cloud-init\$Name-seed.iso"
}
if (-not (Test-Path $SeedIso)) {
    Fehler "Seed-ISO nicht gefunden: $SeedIso"
    Hinweis "In der WSL-Ubuntu bauen:"
    Hinweis "  bash client/cloud-init/make-user-data.sh --hostname $Name --kiosk"
    Hinweis "  bash client/cloud-init/make-seed.sh --hostname $Name"
    exit 1
}

if (-not (Get-VMSwitch -Name $Switch -ErrorAction SilentlyContinue)) {
    Fehler "Virtueller Switch '$Switch' existiert nicht."
    Hinweis ("Vorhanden: " + ((Get-VMSwitch | Select-Object -ExpandProperty Name) -join ", "))
    exit 1
}

$diffPfad = Join-Path $VmPfad "$Name\$Name.vhdx"

# --- Aufraeumen, wenn -Neu --------------------------------------------------
$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($vm -and -not $Neu) {
    Fehler "Die VM '$Name' existiert bereits."
    Hinweis "Mit -Neu wird sie geloescht und frisch aufgesetzt (fuer den naechsten M1-Lauf)."
    exit 1
}
if ($vm -and $Neu) {
    Schritt "Alte VM '$Name' entfernen"
    if ($vm.State -ne "Off") { Stop-VM -Name $Name -TurnOff -Force }
    Remove-VM -Name $Name -Force
    Hinweis "VM geloescht."
}
if ($Neu -and (Test-Path $diffPfad)) {
    Remove-Item $diffPfad -Force
    Hinweis "Alte Differenzplatte geloescht - der naechste Boot ist wieder ein Erstboot."
}

# --- Differenzplatte --------------------------------------------------------
Schritt "Differenzplatte auf das Golden-VHDX anlegen"
New-Item -ItemType Directory -Force -Path (Split-Path $diffPfad -Parent) | Out-Null
New-VHD -Path $diffPfad -ParentPath $Golden -Differencing | Out-Null
Hinweis "$diffPfad  (Eltern: $Golden)"

# --- VM ---------------------------------------------------------------------
Schritt "VM '$Name' anlegen (Generation 2)"
New-VM -Name $Name -MemoryStartupBytes ($RamMB * 1MB) -Generation 2 `
       -VHDPath $diffPfad -SwitchName $Switch -Path $VmPfad | Out-Null

Set-VMProcessor -VMName $Name -Count $Cpu
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
             -MinimumBytes 1024MB -StartupBytes ($RamMB * 1MB) -MaximumBytes 4096MB

# Secure Boot aus - siehe Kopf.
Set-VMFirmware -VMName $Name -EnableSecureBoot Off

# Automatische Pruefpunkte aus: sie legen beim ersten Start einen Checkpoint
# an und verzerren damit genau die Zeit, die M1 misst.
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false
Set-VM -Name $Name -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

Schritt "Seed-ISO als zweites Laufwerk anhaengen"
Add-VMDvdDrive -VMName $Name -Path $SeedIso
Hinweis $SeedIso

# Von der Platte booten, nicht vom ISO - das Seed-ISO ist Datentraeger,
# kein Installationsmedium.
$hdd = Get-VMHardDiskDrive -VMName $Name
Set-VMFirmware -VMName $Name -FirstBootDevice $hdd

Write-Host ""
Schritt "Fertig"
Hinweis ("VM       : {0}   {1} MB RAM, {2} vCPU" -f $Name, $RamMB, $Cpu)
Hinweis ("Platte   : {0}" -f $diffPfad)
Hinweis ("Seed     : {0}" -f $SeedIso)
Hinweis ("Netz     : {0}" -f $Switch)

if ($NichtStarten) {
    Write-Host ""
    Write-Host "Nicht gestartet (-NichtStarten). Start mit:  Start-VM -Name $Name"
    exit 0
}

Write-Host ""
Schritt "Starten - ab hier greift niemand mehr ein"
$startZeit = Get-Date
Start-VM -Name $Name
Write-Host ""
Write-Host ("Startzeit: {0:HH:mm:ss}  <- Nullpunkt fuer M1, notieren." -f $startZeit) -ForegroundColor Yellow
Write-Host ""
Write-Host "Bildschirm oeffnen:   vmconnect.exe localhost $Name"
Write-Host ""
Write-Host "Erwarteter Ablauf ohne jeden Handgriff:"
Write-Host "  ~30 s   cloud-init legt Skripte, Units und agent.env an"
Write-Host "  ~60 s   raumfrei-enroll meldet das Geraet an (POST /enroll)"
Write-Host "  ~2-5 m  erster ansible-pull installiert cage und den Browser"
Write-Host "  danach  der Raumplan steht auf dem Schirm"
Write-Host ""
Write-Host "Dann in der VM messen:"
Write-Host "  sudo bash /pfad/zu/lab/measure_zerotouch.sh --lauf 1 --label $Name"
Write-Host ""
Write-Host "Geht etwas schief, zeigt das Journal es sofort:"
Write-Host "  journalctl -b -u raumfrei-enroll -u raumfrei-agent -u raumfrei-kiosk"
