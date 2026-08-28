<#
    deploy_rooms.ps1 - die BESTEHENDE RaumFrei-Buchungsanwendung ins eigene
    Konto umziehen.

    Der Anwendungscode (RaumFrei_lambda.py) ist unveraendert aus der
    Transferarbeit Cloud & Serverless uebernommen - die Buchungslogik wird
    laut Idee nicht angefasst. Neu ist nur das Deployment. Drei Dinge am alten
    deploy.sh gingen im eigenen Konto nicht:

      1. REGION war us-east-1. Die Flotte lebt in eu-central-1; zwei Regionen
         waeren zwei Latenzen, zwei Rechnungen und zwei Orte zum Aufraeumen.

      2. ROLE_NAME war "LabRole" - die Sammelrolle des AWS-Academy-Kontos.
         Die gibt es hier nicht, und sie waere auch nicht erstrebenswert:
         sie darf so ziemlich alles. Stattdessen eine eigene Rolle, deren
         Policy auf die Tabelle RaumFrei und die eigene Log-Gruppe zeigt.

      3. Das alte Skript legte Integration, Routen und Permission NUR beim
         Anlegen der API an ("API existiert bereits, wird uebersprungen").
         Hier laeuft aber zuerst deploy_devices.ps1 und erzeugt die API
         RaumFreiAPI - das alte Skript haette sie gefunden, alles
         uebersprungen und eine API ohne /rooms-Routen hinterlassen. Der
         Fehler waere still: Deployment "erfolgreich", Anzeige leer.
         Deshalb ist hier jeder Schritt fuer sich idempotent.

    Ergebnis ist eine HTTP-API mit zwoelf Routen und zwei Lambdas: die
    Geraeteseite und die Buchungsseite teilen sich Endpunkt und CORS, bleiben
    aber getrennte Funktionen mit getrennten Rollen und getrennten Tabellen.

    Reihenfolge:  erst .\..\deploy_devices.ps1, dann dieses Skript.
    Ausfuehren:   .\deploy_rooms.ps1
#>

$ErrorActionPreference = "Stop"

$Region      = "eu-central-1"
$TableName   = "RaumFrei"
$LambdaName  = "RaumFreiHandler"
$RoleName    = "RaumFreiRoomLambdaRole"
$PolicyName  = "RaumFreiRoomPolicy"
$ApiName     = "RaumFreiAPI"
$ZipFile     = "rooms_function.zip"
$SecretsFile = Join-Path (Split-Path $PSScriptRoot -Parent) "secrets.env"

Set-Location $PSScriptRoot

# Windows PowerShell 5.1 wirft bei nativen Programmen keine Exception -
# try/catch greift hier NICHT, es zaehlt allein $LASTEXITCODE.
function Invoke-AwsProbe {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & aws @args 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { return $null }
    return ($out | Out-String).Trim()
}

# Windows PowerShell 5.1 schreibt bei "-Encoding utf8" IMMER ein BOM - es gibt
# dort kein "utf8NoBOM" wie ab PowerShell 6. IAM lehnt ein Policy-Dokument mit
# BOM ab, mit der wenig hilfreichen Meldung "MalformedPolicyDocument: Syntax
# errors in policy". Beim ersten Deploy der Geraeteseite am 28.08. genau so
# passiert - und das Skript meldete trotzdem Erfolg.
#
# Der Pfad wird ueber die SessionState aufgeloest: .NET kennt das aktuelle
# Verzeichnis von PowerShell nicht, ein relativer Pfad landete sonst irgendwo.
function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [switch]$NoNewline
    )
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $text = ($Lines -join "`n")
    if (-not $NoNewline -and $text.Length -gt 0) { $text += "`n" }
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host ""
Write-Host "============================================"
Write-Host "  RaumFrei Buchung - Umzug ins eigene Konto"
Write-Host "  Region: $Region"
Write-Host "============================================"
Write-Host ""

# --- 1 Konto ----------------------------------------------------------------
Write-Host "[1/7] AWS-Konto ermitteln..."
$AccountId = (aws sts get-caller-identity --query Account --output text)
Write-Host "      Konto: $AccountId"

# --- 2 DynamoDB -------------------------------------------------------------
Write-Host "[2/7] DynamoDB-Tabelle '$TableName'..."
$tableExists = $null -ne (Invoke-AwsProbe dynamodb describe-table `
    --table-name $TableName --region $Region)

if ($tableExists) {
    Write-Host "      Tabelle existiert bereits."
} else {
    aws dynamodb create-table `
        --table-name $TableName `
        --attribute-definitions AttributeName=roomId,AttributeType=S `
        --key-schema AttributeName=roomId,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST `
        --region $Region | Out-Null
    aws dynamodb wait table-exists --table-name $TableName --region $Region
    Write-Host "      Tabelle erstellt."
}

# --- 3 IAM-Rolle ------------------------------------------------------------
Write-Host "[3/7] IAM-Rolle '$RoleName'..."
$RoleArn = Invoke-AwsProbe iam get-role --role-name $RoleName `
    --query "Role.Arn" --output text

if ($null -eq $RoleArn) {
    $RoleArn = (aws iam create-role `
        --role-name $RoleName `
        --assume-role-policy-document file://../iam/lambda-trust.json `
        --description "Least-Privilege-Rolle fuer RaumFreiHandler (Buchung)" `
        --query "Role.Arn" --output text)
    Write-Host "      Rolle erstellt: $RoleArn"
    Start-Sleep -Seconds 10   # IAM ist eventually consistent
} else {
    Write-Host "      Rolle existiert bereits: $RoleArn"
}

$policy = (Get-Content "iam/rooms-policy.json" -Raw).
    Replace("{{REGION}}", $Region).
    Replace("{{ACCOUNT_ID}}", $AccountId).
    Replace("{{TABLE_NAME}}", $TableName)
$policyPath = Join-Path $env:TEMP "raumfrei-rooms-policy.json"
Write-Utf8NoBom -Path $policyPath -Lines $policy
aws iam put-role-policy --role-name $RoleName --policy-name $PolicyName `
    --policy-document "file://$policyPath" | Out-Null
$policyRc = $LASTEXITCODE
Remove-Item $policyPath

# Ein Deployment, das seinen eigenen Fehlschlag uebergeht, ist schlimmer als
# keines: die Lambda liefe ohne jedes Recht auf die Tabelle und beantwortete
# jede Route mit 502.
if ($policyRc -ne 0) {
    throw "PutRolePolicy fehlgeschlagen (Exit $policyRc). Ohne Policy hat die Lambda keine Rechte auf $TableName."
}
Write-Host "      Policy '$PolicyName' gesetzt (nur Tabelle $TableName + Logs)."

# --- 4 Lambda ---------------------------------------------------------------
Write-Host "[4/7] Lambda '$LambdaName'..."
if (Test-Path $ZipFile) { Remove-Item $ZipFile }
Compress-Archive -Path "RaumFrei_lambda.py" -DestinationPath $ZipFile

$envVars = "Variables={TABLE_NAME=$TableName}"
$lambdaExists = $null -ne (Invoke-AwsProbe lambda get-function `
    --function-name $LambdaName --region $Region)

if ($lambdaExists) {
    aws lambda update-function-code --function-name $LambdaName `
        --zip-file "fileb://$ZipFile" --region $Region | Out-Null
    aws lambda wait function-updated --function-name $LambdaName --region $Region
    aws lambda update-function-configuration --function-name $LambdaName `
        --environment $envVars --region $Region | Out-Null
    aws lambda wait function-updated --function-name $LambdaName --region $Region
    Write-Host "      Code und Konfiguration aktualisiert."
} else {
    aws lambda create-function --function-name $LambdaName `
        --runtime python3.12 --role $RoleArn `
        --handler RaumFrei_lambda.lambda_handler `
        --zip-file "fileb://$ZipFile" `
        --timeout 15 --memory-size 128 `
        --environment $envVars --region $Region | Out-Null
    aws lambda wait function-active --function-name $LambdaName --region $Region
    Write-Host "      Funktion erstellt."
}
$LambdaArn = (aws lambda get-function --function-name $LambdaName --region $Region `
    --query "Configuration.FunctionArn" --output text)

# --- 5 API Gateway ----------------------------------------------------------
Write-Host "[5/7] API Gateway '$ApiName'..."
$Cors = "AllowOrigins=*,AllowMethods=GET,POST,OPTIONS,AllowHeaders=Content-Type,Authorization,X-Admin-Key"
$ApiId = (aws apigatewayv2 get-apis --region $Region `
    --query "Items[?Name=='$ApiName'].ApiId | [0]" --output text)

if ($ApiId -eq "None" -or [string]::IsNullOrWhiteSpace($ApiId)) {
    $ApiId = (aws apigatewayv2 create-api --name $ApiName --protocol-type HTTP `
        --cors-configuration $Cors `
        --region $Region --query "ApiId" --output text)
    aws apigatewayv2 create-stage --api-id $ApiId --stage-name '$default' `
        --auto-deploy --region $Region | Out-Null
    Write-Host "      API neu erstellt (ID: $ApiId)."
    Write-Host "      Hinweis: deploy_devices.ps1 lief offenbar noch nicht." -ForegroundColor Yellow
} else {
    # Dieselbe CORS-Konfiguration wie die Geraeteseite. Laeuft dieses Skript
    # zuerst, fehlten sonst Authorization und X-Admin-Key, und fleet.html
    # scheiterte im Browser am Preflight - serverseitig voellig unauffaellig.
    aws apigatewayv2 update-api --api-id $ApiId --cors-configuration $Cors `
        --region $Region | Out-Null
    Write-Host "      Bestehende API wiederverwendet (ID: $ApiId), CORS abgeglichen."
}

$IntegrationUri = "arn:aws:apigateway:${Region}:lambda:path/2015-03-31/functions/${LambdaArn}/invocations"
$IntegrationId = (aws apigatewayv2 get-integrations --api-id $ApiId --region $Region `
    --query "Items[?IntegrationUri=='$IntegrationUri'].IntegrationId | [0]" --output text)

if ($IntegrationId -eq "None" -or [string]::IsNullOrWhiteSpace($IntegrationId)) {
    $IntegrationId = (aws apigatewayv2 create-integration --api-id $ApiId `
        --integration-type AWS_PROXY `
        --integration-uri $IntegrationUri `
        --payload-format-version 2.0 --region $Region --query "IntegrationId" --output text)
    Write-Host "      Integration erstellt (ID: $IntegrationId)."
} else {
    Write-Host "      Integration wiederverwendet (ID: $IntegrationId)."
}

# OPTIONS /{proxy+} aus dem alten Skript entfaellt: bei einer HTTP-API mit
# gesetzter CORS-Konfiguration beantwortet API Gateway den Preflight selbst.
# Die Route wuerde ausserdem JEDEN OPTIONS-Aufruf - auch den der
# Geraeteseite - an die Buchungs-Lambda haengen.
$routes = @(
    "GET /rooms",
    "POST /rooms/book",
    "POST /rooms/release"
)

$existing = (aws apigatewayv2 get-routes --api-id $ApiId --region $Region `
    --query "Items[].{Key:RouteKey,Id:RouteId}" --output json) | ConvertFrom-Json

foreach ($route in $routes) {
    $match = $existing | Where-Object { $_.Key -eq $route }
    if ($match) {
        aws apigatewayv2 update-route --api-id $ApiId --route-id $match.Id `
            --target "integrations/$IntegrationId" --region $Region | Out-Null
        Write-Host "      ~ $route (auf neue Integration umgehaengt)"
    } else {
        aws apigatewayv2 create-route --api-id $ApiId --route-key $route `
            --target "integrations/$IntegrationId" --region $Region | Out-Null
        Write-Host "      + $route"
    }
}

$permission = Invoke-AwsProbe lambda add-permission --function-name $LambdaName `
    --statement-id "apigw-$ApiId" --action lambda:InvokeFunction `
    --principal apigateway.amazonaws.com `
    --source-arn "arn:aws:execute-api:${Region}:${AccountId}:${ApiId}/*/*" `
    --region $Region

if ($null -ne $permission) {
    Write-Host "      Permission gesetzt."
} else {
    Write-Host "      Permission existiert bereits."
}

$ApiUrl = "https://$ApiId.execute-api.$Region.amazonaws.com"

# --- 6 Frontend nachziehen ---------------------------------------------------
Write-Host "[6/7] RaumFrei.html auf die neue API zeigen lassen..."
$html = Get-Content "RaumFrei.html" -Raw
$patched = [regex]::Replace($html, 'const API_BASE = "https://[^"]*"', "const API_BASE = `"$ApiUrl`"")
if ($patched -ne $html) {
    Write-Utf8NoBom -Path "RaumFrei.html" -Lines $patched -NoNewline
    Write-Host "      API_BASE gesetzt auf: $ApiUrl"
} else {
    Write-Host "      API_BASE zeigte bereits auf: $ApiUrl"
}

# --- 7 Anzeigeseiten der Flotte auf /rooms zeigen lassen ---------------------
# Die Tuerschilder holen ihren Plan nicht aus RaumFrei.html, sondern aus
# roomsApiUrl im globalen Soll-Zustand. Ohne diesen Schritt zeigt jedes
# Display "kein Stand verfuegbar" - und die Ursache liegt dann im Backend,
# nicht am Geraet, was beim Suchen teuer ist.
Write-Host "[7/7] roomsApiUrl im Soll-Zustand setzen..."
if (Test-Path $SecretsFile) {
    $secrets = @{}
    Get-Content $SecretsFile | ForEach-Object {
        if ($_ -match "^([A-Z_]+)=(.*)$") { $secrets[$Matches[1]] = $Matches[2] }
    }
    if ($secrets.ContainsKey("ADMIN_KEY") -and $secrets.ContainsKey("BACKEND_URL")) {
        try {
            Invoke-RestMethod -Method Post -Uri "$($secrets.BACKEND_URL)/settings" `
                -Headers @{ "X-Admin-Key" = $secrets.ADMIN_KEY } `
                -ContentType "application/json" `
                -Body (@{ roomsApiUrl = $ApiUrl } | ConvertTo-Json) | Out-Null
            Write-Host "      roomsApiUrl = $ApiUrl gesetzt."
        } catch {
            Write-Host "      Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "      Von Hand: POST $($secrets.BACKEND_URL)/settings  {""roomsApiUrl"":""$ApiUrl""}"
        }
    } else {
        Write-Host "      ADMIN_KEY/BACKEND_URL fehlen in secrets.env - Schritt uebersprungen."
    }
} else {
    Write-Host "      secrets.env fehlt (deploy_devices.ps1 noch nicht gelaufen) - Schritt uebersprungen."
}

Write-Host ""
Write-Host "============================================"
Write-Host "  Fertig."
Write-Host "============================================"
Write-Host "  API-URL : $ApiUrl"
Write-Host ""
Write-Host "  Naechste Schritte:"
Write-Host "    1. `$env:AWS_DEFAULT_REGION=`"$Region`"; python seed_rooms.py"
Write-Host "    2. RaumFrei.html im Browser oeffnen - API-Status muss gruen sein"
Write-Host "    3. curl $ApiUrl/rooms"
Write-Host ""
