# Deploys Writer & Critic to Google Cloud Run in one go. Safe to run again: every step skips what already exists.
#
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1
#
# Needs gcloud, logged in and set to the project that runs the Workbench (gcloud config list).
# Asks for your OpenAI key the first time only. Keys are never printed.
param(
    [string]$Region = "us-central1",
    [string]$Service = "writer-critic",
    [string]$Version = "v1"
)

$WorkbenchKeySecret = "writer-critic-workbench-key"
$OpenAIKeySecret = "writer-critic-openai-key"

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "`nStopped: $text" -ForegroundColor Red; exit 1 }

function SecretExists($name) {
    gcloud secrets describe $name --format="value(name)" 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function ReadSecret($name) {
    $value = gcloud secrets versions access latest --secret=$name 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return ($value | Out-String).Trim()
}

function SaveSecret($name, $value) {
    # Written to a file first, so no line break ends up in the secret.
    $file = Join-Path $env:TEMP "$name.txt"
    [IO.File]::WriteAllText($file, $value)
    if (SecretExists $name) { gcloud secrets versions add $name --data-file="$file" | Out-Null }
    else { gcloud secrets create $name --data-file="$file" | Out-Null }
    $ok = $LASTEXITCODE -eq 0
    Remove-Item $file -ErrorAction SilentlyContinue
    if (-not $ok) { Fail "could not save the secret $name." }
}

function StatusCode($err) {
    if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode }
    return 0
}

Step "Checking gcloud"
$project = (gcloud config get-value project 2>$null | Out-String).Trim()
if (-not $project) { Fail "no gcloud project is set. Run: gcloud config set project YOUR_PROJECT_ID" }
$projectNumber = (gcloud projects describe $project --format="value(projectNumber)" | Out-String).Trim()
$wb = (gcloud run services describe eval-workbench --region $Region --format="value(status.url)" 2>$null | Out-String).Trim()
if (-not $wb) { Fail "the eval-workbench service was not found in project $project ($Region)." }
Write-Host "Project $project, Workbench at $wb"

Step "Workbench project 'writer-critic'"
$admin = ReadSecret "eval-workbench-admin"
if (-not $admin) { Fail "could not read the secret eval-workbench-admin." }
$adminHeaders = @{ Authorization = "Bearer $admin" }
try {
    Invoke-RestMethod -Method Post -Uri "$wb/admin/projects" -Headers $adminHeaders -ContentType "application/json" `
        -Body '{"name":"Writer and Critic","id":"writer-critic"}' | Out-Null
    Write-Host "Created."
} catch {
    if ((StatusCode $_) -eq 409) { Write-Host "Already exists." } else { Fail "could not create it: $($_.Exception.Message)" }
}

Step "Workbench key for the app"
$key = ReadSecret $WorkbenchKeySecret
$keyWorks = $false
if ($key) {
    try {
        Invoke-RestMethod -Uri "$wb/settings/judge" -Headers @{ Authorization = "Bearer $key" } | Out-Null
        $keyWorks = $true
    } catch { }
}
if ($keyWorks) {
    Write-Host "The saved key works."
} else {
    try {
        $created = Invoke-RestMethod -Method Post -Uri "$wb/admin/projects/writer-critic/keys" -Headers $adminHeaders `
            -ContentType "application/json" -Body '{"name":"cloud run"}'
    } catch { Fail "could not create a key: $($_.Exception.Message)" }
    SaveSecret $WorkbenchKeySecret $created.key
    Write-Host "Created a new key and saved it in Secret Manager as $WorkbenchKeySecret."
}

Step "OpenAI key"
if (SecretExists $OpenAIKeySecret) {
    Write-Host "Already saved in Secret Manager as $OpenAIKeySecret."
} else {
    $secure = Read-Host "Paste your OpenAI API key (sk-...), then press Enter" -AsSecureString
    $openai = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()
    if (-not $openai.StartsWith("sk-")) { Fail "that doesn't look like an OpenAI key (they start with sk-)." }
    SaveSecret $OpenAIKeySecret $openai
    Write-Host "Saved in Secret Manager as $OpenAIKeySecret."
}

Step "Letting Cloud Run read both secrets"
$member = "serviceAccount:$projectNumber-compute@developer.gserviceaccount.com"
foreach ($name in @($WorkbenchKeySecret, $OpenAIKeySecret)) {
    gcloud secrets add-iam-policy-binding $name --member=$member --role=roles/secretmanager.secretAccessor --quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "could not give Cloud Run access to $name." }
}
Write-Host "Done."

Step "Building and deploying (takes a few minutes)"
gcloud run deploy $Service --source . --region $Region --no-allow-unauthenticated --no-cpu-throttling --max-instances 1 `
    --set-env-vars "EVAL_WORKBENCH_URL=$wb,APP_VERSION=$Version" `
    --set-secrets "OPENAI_API_KEY=${OpenAIKeySecret}:latest,EVAL_WORKBENCH_API_KEY=${WorkbenchKeySecret}:latest"
if ($LASTEXITCODE -ne 0) { Fail "the deploy failed. The error is above." }

Step "Deployed"
Write-Host "The app is private. To open it, run:"
Write-Host "  gcloud run services proxy $Service --region $Region --port 8200"
Write-Host "then open http://127.0.0.1:8200 in your browser."
