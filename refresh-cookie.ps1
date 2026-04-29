# Cookie refresh helper.
# Run when the widget shows "AUTH FAILED - refresh cookie".
#
#   1. Open claude.ai in Chrome, log in.
#   2. F12 -> Network -> filter "usage" -> Fetch/XHR.
#   3. Reload Settings -> Usage page (Ctrl+Shift+R).
#   4. Click the "usage" request -> Headers -> scroll to Request Headers.
#   5. Right-click the "Cookie:" header value -> Copy value.
#   6. Run this script and paste when prompted.

$configPath = Join-Path $PSScriptRoot "config.json"

if (-not (Test-Path $configPath)) {
    Write-Host "Config file missing: $configPath" -ForegroundColor Red
    Write-Host "Copy config.example.json to config.json first." -ForegroundColor Yellow
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json
Write-Host ""
Write-Host "Current org_id: $($config.org_id)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Paste the new Cookie header value (one long line), then press Enter:" -ForegroundColor Yellow
$newCookie = Read-Host

if ([string]::IsNullOrWhiteSpace($newCookie)) {
    Write-Host "No cookie entered. Aborted." -ForegroundColor Red
    exit 1
}

if ($newCookie -notmatch "sessionKey=") {
    Write-Host "Warning: pasted string does not contain 'sessionKey=' - are you sure?" -ForegroundColor Yellow
    $confirm = Read-Host "Save anyway? (y/N)"
    if ($confirm -ne "y") { exit 1 }
}

$config.cookie = $newCookie.Trim()
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding utf8

Write-Host ""
Write-Host "Cookie updated. The widget will pick it up on its next poll (within 60s)." -ForegroundColor Green
Write-Host ""
