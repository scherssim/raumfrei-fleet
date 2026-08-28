<#
    deploy_devices.ps1 - Geraeteseite von RaumFrei nach AWS deployen.

    Nachfolger von Cloud_Serverless/Unterricht/Transferarbeit/deploy.ps1, aber:
      * Region eu-central-1 statt us-east-1
      * eigene IAM-Rolle mit Least-Privilege-Policy statt der LabRole des
        AWS-Academy-Kontos
      * Secrets werden beim ersten Lauf erzeugt und in secrets.env abgelegt
        (gitignored), damit ein Re-Deploy dieselben Werte weiterverwendet -
        sonst muessten sich alle Geraete neu anmelden.

    Voraussetzung: aws configure (eigenes Konto), Rechte fuer IAM/Lambda/
    DynamoDB/API Gateway.

    Ausfuehren:  .\deploy_devices.ps1
#>

$ErrorActionPreference = "Stop"

$Region      = "eu-central-1"
$TableName   = "Devices"
$LambdaName  = "RaumFreiDeviceHandler"
$RoleName    = "RaumFreiDeviceLambdaRole"
$PolicyName  = "RaumFreiDevicePolicy"
$ApiName     = "RaumFreiAPI"
$ZipFile     = "device_function.zip"
$SecretsFile = Join-Path $PSScriptRoot "secrets.env"

Set-Location $PSScriptRoot

# Ein AWS-Aufruf, der fehlschlagen DARF (Pruefung auf Vorhandensein).
# Achtung: Windows PowerShell 5.1 wirft bei nativen Programmen keine Exception,
# try/catch greift hier NICHT - es zaehlt allein $LASTEXITCODE.
# Rueckgabe: Ausgabe als String, oder $null wenn der Aufruf fehlgeschlagen ist.
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
# dort kein "utf8NoBOM" wie ab PowerShell 6. Das kostet an zwei Stellen:
#
#   * IAM lehnt ein Policy-Dokument mit BOM ab, mit der wenig hilfreichen
#     Meldung "MalformedPolicyDocument: Syntax errors in policy".
#   * bash bricht beim Einlesen von secrets.env ueber der ersten Zeile ab
#     ("DEVICE_ID_SALT=...: command not found"), weil das BOM Teil des
#     Variablennamens wird. test_api.sh laeuft dann mit leerem Salt.
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
Write-Host "  RaumFrei Geraeteseite - Deployment"
Write-Host "  Region: $Region"
Write-Host "============================================"
Write-Host ""

# --- 1 Konto ----------------------------------------------------------------
Write-Host "[1/7] AWS-Konto ermitteln..."
$AccountId = (aws sts get-caller-identity --query Account --output text)
Write-Host "      Konto: $AccountId"

# --- 2 Secrets --------------------------------------------------------------
Write-Host "[2/7] Secrets..."
if (Test-Path $SecretsFile) {
    $secrets = @{}
    Get-Content $SecretsFile | ForEach-Object {
        if ($_ -match "^([A-Z_]+)=(.*)$") { $secrets[$Matches[1]] = $Matches[2] }
    }
    Write-Host "      secrets.env gefunden, Werte werden wiederverwendet."
} else {
    # RandomNumberGenerator::Fill() gibt es erst ab .NET Core 2.0. Windows
    # PowerShell 5.1 laeuft auf .NET Framework 4.x und antwortet mit
    # "MethodNotFound". ::Create() existiert in beiden Welten und liefert
    # denselben kryptographisch sicheren Generator - Get-Random taete es NICHT,
    # der ist nicht fuer Geheimnisse gedacht.
    function New-Secret {
        $bytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        return [System.BitConverter]::ToString($bytes).Replace("-", "").ToLower()
    }
    $secrets = @{
        ENROLL_SECRET   = New-Secret
        ADMIN_KEY       = New-Secret
        DEVICE_ID_SALT  = New-Secret
    }
    $lines = $secrets.Keys | ForEach-Object { "$_=$($secrets[$_])" }
    Write-Utf8NoBom -Path $SecretsFile -Lines $lines
    Write-Host "      Neue Secrets erzeugt und in secrets.env abgelegt."
    Write-Host "      ACHTUNG: Diese Datei gehoert NICHT ins Git-Repo." -ForegroundColor Yellow
}

# --- 3 DynamoDB -------------------------------------------------------------
Write-Host "[3/7] DynamoDB-Tabelle '$TableName'..."
$tableExists = $null -ne (Invoke-AwsProbe dynamodb describe-table `
    --table-name $TableName --region $Region)

if ($tableExists) {
    Write-Host "      Tabelle existiert bereits."
} else {
    aws dynamodb create-table `
        --table-name $TableName `
        --attribute-definitions AttributeName=deviceId,AttributeType=S `
        --key-schema AttributeName=deviceId,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST `
        --region $Region | Out-Null
    aws dynamodb wait table-exists --table-name $TableName --region $Region
    # TTL raeumt die Nonce-Items automatisch weg - ohne das waechst die Tabelle
    # mit jedem Enrollment-Versuch monoton.
    aws dynamodb update-time-to-live `
        --table-name $TableName `
        --time-to-live-specification "Enabled=true,AttributeName=expiresAt" `
        --region $Region | Out-Null
    Write-Host "      Tabelle erstellt, TTL auf expiresAt aktiviert."
}

# --- 4 IAM-Rolle ------------------------------------------------------------
Write-Host "[4/7] IAM-Rolle '$RoleName'..."
$RoleArn = Invoke-AwsProbe iam get-role --role-name $RoleName `
    --query "Role.Arn" --output text
$roleExists = $null -ne $RoleArn

if (-not $roleExists) {
    $RoleArn = (aws iam create-role `
        --role-name $RoleName `
        --assume-role-policy-document file://iam/lambda-trust.json `
        --description "Least-Privilege-Rolle fuer RaumFreiDeviceHandler" `
        --query "Role.Arn" --output text)
    Write-Host "      Rolle erstellt: $RoleArn"
    Start-Sleep -Seconds 10   # IAM ist eventually consistent
} else {
    Write-Host "      Rolle existiert bereits: $RoleArn"
}

# Policy immer neu schreiben - so wirkt eine Aenderung an devices-policy.json
# auch bei einem Re-Deploy.
$policy = (Get-Content "iam/devices-policy.json" -Raw).
    Replace("{{REGION}}", $Region).
    Replace("{{ACCOUNT_ID}}", $AccountId).
    Replace("{{TABLE_NAME}}", $TableName)
$policyPath = Join-Path $env:TEMP "raumfrei-devices-policy.json"
Write-Utf8NoBom -Path $policyPath -Lines $policy
aws iam put-role-policy --role-name $RoleName --policy-name $PolicyName `
    --policy-document "file://$policyPath" | Out-Null
$policyRc = $LASTEXITCODE
Remove-Item $policyPath

# Ohne diese Pruefung meldete das Skript "Policy gesetzt", obwohl IAM
# abgelehnt hatte - die Lambda stand danach ohne jedes Recht auf die Tabelle
# da und haette jede Route mit 502 beantwortet. Ein Deployment, das seinen
# eigenen Fehlschlag uebergeht, ist schlimmer als keines.
if ($policyRc -ne 0) {
    throw "PutRolePolicy fehlgeschlagen (Exit $policyRc). Ohne Policy hat die Lambda keine Rechte auf $TableName."
}
Write-Host "      Policy '$PolicyName' gesetzt (nur Tabelle $TableName + Logs)."

# --- 5 Lambda ---------------------------------------------------------------
Write-Host "[5/7] Lambda '$LambdaName'..."
if (Test-Path $ZipFile) { Remove-Item $ZipFile }
Compress-Archive -Path "device_handler.py" -DestinationPath $ZipFile

$envVars = "Variables={DEVICES_TABLE=$TableName," +
           "ENROLL_SECRET=$($secrets.ENROLL_SECRET)," +
           "ADMIN_KEY=$($secrets.ADMIN_KEY)," +
           "DEVICE_ID_SALT=$($secrets.DEVICE_ID_SALT)}"

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
        --handler device_handler.lambda_handler `
        --zip-file "fileb://$ZipFile" `
        --timeout 15 --memory-size 128 `
        --environment $envVars --region $Region | Out-Null
    aws lambda wait function-active --function-name $LambdaName --region $Region
    Write-Host "      Funktion erstellt."
}
$LambdaArn = (aws lambda get-function --function-name $LambdaName --region $Region `
    --query "Configuration.FunctionArn" --output text)

# --- 6 API Gateway ----------------------------------------------------------
Write-Host "[6/7] API Gateway '$ApiName'..."
$ApiId = (aws apigatewayv2 get-apis --region $Region `
    --query "Items[?Name=='$ApiName'].ApiId | [0]" --output text)

if ($ApiId -eq "None" -or [string]::IsNullOrWhiteSpace($ApiId)) {
    $ApiId = (aws apigatewayv2 create-api --name $ApiName --protocol-type HTTP `
        --cors-configuration "AllowOrigins=*,AllowMethods=GET,POST,OPTIONS,AllowHeaders=Content-Type,Authorization,X-Admin-Key" `
        --region $Region --query "ApiId" --output text)
    aws apigatewayv2 create-stage --api-id $ApiId --stage-name '$default' `
        --auto-deploy --region $Region | Out-Null
    Write-Host "      API neu erstellt (ID: $ApiId)."
} else {
    Write-Host "      Bestehende API wiederverwendet (ID: $ApiId)."
}

# Vorhandene Integration wiederverwenden. Sonst entsteht bei jedem Re-Deploy
# eine neue und die alten bleiben als Karteileichen an der API haengen.
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

$routes = @(
    "POST /enroll",
    "GET /config/{deviceId}",
    "POST /checkin",
    "GET /devices",
    "POST /devices/{deviceId}/assign",
    "POST /devices/{deviceId}/revoke",
    "POST /devices/{deviceId}/retire",
    "GET /settings",
    "POST /settings"
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

# Lambda-Permission: API Gateway darf die Funktion aufrufen.
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

# --- 7 Ergebnis -------------------------------------------------------------
$ApiUrl = "https://$ApiId.execute-api.$Region.amazonaws.com"
$content = Get-Content $SecretsFile | Where-Object { $_ -notmatch "^BACKEND_URL=" -and $_ -ne "" }
$content += "BACKEND_URL=$ApiUrl"
Write-Utf8NoBom -Path $SecretsFile -Lines $content

Write-Host ""
Write-Host "[7/7] Fertig."
Write-Host "      Backend-URL: $ApiUrl"
Write-Host "      Secrets:     $SecretsFile"
Write-Host ""
Write-Host "      Naechster Schritt:  bash test_api.sh"
Write-Host ""
