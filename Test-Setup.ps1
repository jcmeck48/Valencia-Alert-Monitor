# Checks a hub PC's alarm-monitor setup end to end and prints PASS / FAIL for each step.
# Run from the RMSMonitor folder:  powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Setup.ps1
# Add -SkipSlack to skip the real Slack test post.
param([switch]$SkipSlack)

$dir     = $PSScriptRoot
$monitor = Join-Path $dir 'SeriousAlarmMonitor.ps1'
$results = New-Object System.Collections.ArrayList

function Add-Result([string]$step, [string]$status, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ Step = $step; Result = $status; Detail = $detail })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; SKIP = 'Gray' }[$status]
    Write-Host ("[{0}] {1} - {2}" -f $status, $step, $detail) -ForegroundColor $color
}

function Invoke-MonitorTest([string]$switch) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitor $switch | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    return $LASTEXITCODE
}

Write-Host "`n=== RMS Alarm Monitor - setup test ===`n" -ForegroundColor Cyan

# 1. Files
$missing = @('SeriousAlarmMonitor.ps1', 'MapSnapshot.ps1', 'Install-Monitor.ps1', 'config.json') | Where-Object { -not (Test-Path (Join-Path $dir $_)) }
if ($missing) { Add-Result 'Files' 'FAIL' "missing: $($missing -join ', ')"; exit 1 }
Add-Result 'Files' 'PASS' 'all 4 files present'

# 2. Config
try { $cfg = Get-Content (Join-Path $dir 'config.json') -Raw | ConvertFrom-Json }
catch { Add-Result 'Config' 'FAIL' "config.json is not valid JSON: $($_.Exception.Message)"; exit 1 }
$raw = Get-Content (Join-Path $dir 'config.json') -Raw
if ($raw -match 'FIX_ME|PASTE') { Add-Result 'Config' 'FAIL' 'config.json still has a placeholder (FIX_ME / PASTE) - fill it in'; exit 1 }
if ($cfg.RmsBaseUrl -notmatch '^https?://\d{1,3}(\.\d{1,3}){3}(:\d+)?$') { Add-Result 'Config' 'WARN' "RmsBaseUrl looks unusual: $($cfg.RmsBaseUrl)" }
if ($cfg.Slack.ChannelId -notmatch '^[CG][A-Z0-9]{8,}$') { Add-Result 'Config' 'FAIL' "ChannelId must be a channel ID like C07ABC123, not a name (got '$($cfg.Slack.ChannelId)')"; exit 1 }
Add-Result 'Config' 'PASS' "$($cfg.SiteName) | $($cfg.RmsBaseUrl) | channel $($cfg.Slack.ChannelId) | threshold $($cfg.ThresholdMinutes) min"
if ($cfg.ThresholdMinutes -lt 5) { Add-Result 'Threshold' 'WARN' "ThresholdMinutes is $($cfg.ThresholdMinutes) - fine for testing, set back to 20 for normal use" }

# 3. Network
$uri  = [Uri]$cfg.RmsBaseUrl
$port = if ($uri.IsDefaultPort) { if ($uri.Scheme -eq 'https') { 443 } else { 80 } } else { $uri.Port }
if ((Test-NetConnection $uri.Host -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded) { Add-Result 'Network' 'PASS' "RMS reachable at $($uri.Host):$port" }
else { Add-Result 'Network' 'FAIL' "cannot reach $($uri.Host):$port from this PC - check the IP / network"; exit 1 }

# 4. RMS login + alarm read
Write-Host "`n  Logging in and reading alarms..." -ForegroundColor Cyan
if ((Invoke-MonitorTest '-TestOnce') -eq 0) { Add-Result 'RMS login + alarms' 'PASS' 'logged in and read Serious alarms (see list above)' }
else { Add-Result 'RMS login + alarms' 'FAIL' 'see ERROR line above (wrong login, or different RMS version)'; exit 1 }

# 5. Map screenshot
Write-Host "`n  Taking map screenshot (up to ~60 s)..." -ForegroundColor Cyan
$png = Join-Path $dir 'map-test.png'
Remove-Item $png -ErrorAction SilentlyContinue
if ((Invoke-MonitorTest '-TestSnapshot') -eq 0 -and (Test-Path $png) -and (Get-Item $png).Length -gt 20000) {
    Add-Result 'Map screenshot' 'PASS' "saved map-test.png ($([int]((Get-Item $png).Length / 1KB)) KB) - open it to check it shows the map"
} else { Add-Result 'Map screenshot' 'WARN' 'screenshot failed - alerts will still post as text only' }

# 6. Slack
if ($SkipSlack) { Add-Result 'Slack post' 'SKIP' 'skipped (-SkipSlack)' }
else {
    Write-Host "`n  Posting ONE test message to Slack..." -ForegroundColor Cyan
    switch (Invoke-MonitorTest '-TestSlack') {
        0       { Add-Result 'Slack post' 'PASS' 'test message + map posted - check the channel' }
        2       { Add-Result 'Slack post' 'WARN' 'text posted but NO image - add files:write scope to the Slack app and reinstall it' }
        default { Add-Result 'Slack post' 'FAIL' 'nothing posted - check BotToken, and that the bot is invited to the channel' }
    }
}

# 7. Background task
$task = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'RMS Serious Alarm Monitor*' }
if ($task) { Add-Result 'Background task' $(if ($task.State -eq 'Running') { 'PASS' } else { 'WARN' }) "$($task.TaskName): $($task.State)" }
else { Add-Result 'Background task' 'WARN' 'not installed yet (or run this as admin to see it) - run Install-Monitor.ps1 as admin' }

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($results.Result -contains 'FAIL') { exit 1 } else { exit 0 }
