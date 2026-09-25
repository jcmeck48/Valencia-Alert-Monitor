<#
  Geek+ RMS "Serious" alarm monitor -> Slack
  - Polls /athena/warehouse/monitor/queryEvent for Serious (eventLevel=3) + Unprocessed (faultStatus=0)
  - Alerts once an alarm has been unprocessed longer than ThresholdMinutes
  - Sends a "resolved" follow-up when that same alarm (by id) is processed
  - Attaches a live screenshot of the RMS map to each alert (MapSnapshot.ps1)
  Usage: powershell -ExecutionPolicy Bypass -File SeriousAlarmMonitor.ps1 -ConfigPath .\config.json
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$TestOnce,     # log in, query once, print what it would send; no Slack, no state saved
    [switch]$TestSnapshot, # take one map screenshot to map-test.png; no Slack
    [switch]$TestSlack     # post ONE real test message (with map) to the configured channel
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MapSnapshot.ps1')
$cfg       = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$base      = $cfg.RmsBaseUrl.TrimEnd('/')
$statePath = Join-Path $PSScriptRoot ("state-{0}.json" -f ($cfg.SiteName -replace '\W', ''))
$logPath   = Join-Path $PSScriptRoot ("monitor-{0}.log" -f ($cfg.SiteName -replace '\W', ''))
$session   = $null

function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

function Get-EpochMs([datetime]$dt) { [int64]($dt.ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds }
function ConvertFrom-EpochMs($ms)   { if ($ms) { [datetimeoffset]::FromUnixTimeMilliseconds([int64]$ms).LocalDateTime } }

# Turn RMS language keys into readable text
$friendly = @{
    'lang.rms.monitor.browser.stop'                        = 'System emergency stop (triggered from RMS browser)'
    'lang.rms.monitor.area.robotAbnormalCountException'    = 'Too many abnormal robots in area'
    'lang.rms.fed.device'                                  = 'Device'
    'lang.rms.fed.optionArea'                              = 'Area'
    'lang.rms.fed.optionError'                             = 'Error'
    'lang.rms.fed.optionWarning'                           = 'Warning'
}
function Get-Friendly($key) {
    if (-not $key) { return '' }
    if ($friendly.ContainsKey($key)) { return $friendly[$key] }
    return ($key -replace '^lang\.rms\.(monitor|fed)\.', '')
}

# ---------------------------------------------------------------------------
# LOGIN - same flow as the QR Code Loss report: GSS login, then hand the
# session token to the RMS (athena) backend like the web UI's embedded map does.
# ---------------------------------------------------------------------------
$script:token = $null

function Find-Token($obj, [int]$depth = 0) {
    if ($null -eq $obj -or $depth -gt 4) { return $null }
    if ($obj -is [string]) { if ($obj -match '^gek-[0-9a-f-]{20,}$') { return $obj } else { return $null } }
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Value -is [string] -and $p.Name -match 'token|cred' -and $p.Value.Length -gt 10) { return $p.Value }
        $t = Find-Token $p.Value ($depth + 1)
        if ($t) { return $t }
    }
    return $null
}

function Connect-Rms {
    $script:session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $script:token   = $null
    $body = @{ userName = $cfg.Username; password = $cfg.Password; subsystemCode = 'ALL'; curLanguage = 'en_us'; module = 'AC' } |
        ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Uri "$base/mantis/api/coreresource/auth/login/v1" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' `
        -Headers @{ 'Accept-Language' = 'en_us' } -WebSession $script:session -TimeoutSec 20
    if ($resp.code -ne 0) { throw "RMS login failed: code=$($resp.code) msg=$($resp.msg)" }
    $script:token = Find-Token $resp.data
    if (-not $script:token) {
        foreach ($c in $script:session.Cookies.GetCookies([Uri]$base)) { if ($c.Name -match 'token') { $script:token = $c.Value } }
    }
    if ($script:token) {
        Invoke-WebRequest -Uri "$base/athena/warehouse/auth/monitor?token=$($script:token)" -WebSession $script:session `
            -UseBasicParsing -TimeoutSec 20 | Out-Null
    }
    Write-Log 'Logged in to RMS'
}

function Get-SeriousEvents([string]$faultStatus) {
    $now  = Get-Date
    $body = @{
        eventGroup  = 2
        eventType   = ''
        eventLevel  = 3            # Serious
        faultStatus = $faultStatus # 0 = unprocessed, 1 = processed
        startTime   = Get-EpochMs $now.AddDays(-$cfg.LookbackDays)
        endTime     = Get-EpochMs $now.AddHours(1)
        pageSize    = 100
        currentPage = 1
    }
    $params = @{
        Uri         = "$base/athena/warehouse/monitor/queryEvent"
        Method      = 'Post'
        Body        = $body
        ContentType = 'application/x-www-form-urlencoded;charset=UTF-8'
        Headers     = @{ 'Accept-Language' = 'en_us'; 'Gek-Authorization' = $script:token }
        WebSession  = $script:session
        TimeoutSec  = 20
    }
    $resp = Invoke-RestMethod @params
    if ($resp.code -ne 0) {
        # Treat any non-OK code as a possible expired session: re-login once and retry
        Connect-Rms
        $params.WebSession = $script:session
        $params.Headers['Gek-Authorization'] = $script:token
        $resp = Invoke-RestMethod @params
        if ($resp.code -ne 0) { throw "queryEvent failed: code=$($resp.code) msg=$($resp.msg)" }
    }
    return @($resp.data.recordList)
}

function Send-Slack([string]$text) {
    if ($TestOnce) { Write-Log "[TEST - not sent] $text"; return }
    $payload = @{ channel = $cfg.Slack.ChannelId; text = $text } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Uri 'https://slack.com/api/chat.postMessage' -Method Post `
        -Headers @{ Authorization = "Bearer $($cfg.Slack.BotToken)" } `
        -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20
    if (-not $r.ok) { throw "Slack post failed: $($r.error)" }
}

function Send-SlackImage([string]$text, [string]$path) {
    if ($TestOnce) { Write-Log "[TEST - not sent] $text  (+ image $path)"; return }
    $auth = @{ Authorization = "Bearer $($cfg.Slack.BotToken)" }
    $name = Split-Path $path -Leaf
    $u = Invoke-RestMethod -Method Post -Uri 'https://slack.com/api/files.getUploadURLExternal' -Headers $auth `
        -Body @{ filename = $name; length = (Get-Item $path).Length } -TimeoutSec 30
    if (-not $u.ok) { throw "Slack getUploadURL failed: $($u.error)" }
    Invoke-WebRequest -Method Post -Uri $u.upload_url -InFile $path -ContentType 'image/png' -UseBasicParsing -TimeoutSec 60 | Out-Null
    $payload = @{
        files           = @(@{ id = $u.file_id; title = "RMS map - $($cfg.SiteName)" })
        channel_id      = $cfg.Slack.ChannelId
        initial_comment = $text
    } | ConvertTo-Json -Depth 5 -Compress
    $c = Invoke-RestMethod -Method Post -Uri 'https://slack.com/api/files.completeUploadExternal' -Headers $auth `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 30
    if (-not $c.ok) { throw "Slack completeUpload failed: $($c.error)" }
}

function New-MapSnapshot([string]$outFile) {
    $m = $cfg.MapSnapshot
    Get-RmsMapSnapshot -BaseUrl $base -Username $cfg.Username -Password $cfg.Password -OutFile $outFile `
        -WorkDir $PSScriptRoot -MapPath $m.MapPath -SettleSeconds $m.SettleSeconds -Port $m.DebugPort `
        -Width $m.Width -Height $m.Height
}

# Alert text always goes out; the screenshot is a best-effort extra
function Send-Alert([string]$text) {
    $img = $null
    if ($cfg.MapSnapshot -and $cfg.MapSnapshot.Enabled) {
        try { $img = New-MapSnapshot (Join-Path $PSScriptRoot 'map-latest.png') }
        catch { Write-Log "Map snapshot failed: $($_.Exception.Message)" }
    }
    if ($img) {
        try { Send-SlackImage $text $img; return $true }
        catch { Write-Log "Image upload failed, sending text only: $($_.Exception.Message)" }
    }
    Send-Slack $text
    return $false   # text went out, image did not
}

# Dead-man's switch: tell healthchecks.io (or similar) "still alive" after each good cycle.
# Never allowed to break monitoring - failures are only logged, and only once until it works again.
$script:heartbeatFailing = $false
function Send-Heartbeat {
    $url = $cfg.Heartbeat.PingUrl
    if (-not $url -or $TestOnce) { return }
    try {
        Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 | Out-Null
        if ($script:heartbeatFailing) { Write-Log 'Heartbeat ping working again'; $script:heartbeatFailing = $false }
    } catch {
        if (-not $script:heartbeatFailing) { Write-Log "Heartbeat ping failed: $($_.Exception.Message)"; $script:heartbeatFailing = $true }
    }
}

function Format-Duration([timespan]$ts) {
    if ($ts.TotalHours -ge 1) { return '{0}h {1}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes }
    return '{0}m' -f [int][math]::Floor($ts.TotalMinutes)
}

function Load-State {
    if (Test-Path $statePath) {
        $h = @{}
        (Get-Content $statePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
        return $h
    }
    return @{}
}
function Save-State($state) { if ($TestOnce) { return }; $state | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding utf8 }

# ---------------------------------------------------------------------------
if ($TestSnapshot) {
    $out = Join-Path $PSScriptRoot 'map-test.png'
    Write-Log 'TEST: taking map screenshot (can take ~30-60 s)...'
    New-MapSnapshot $out | Out-Null
    Write-Log "TEST: saved $out"
    exit 0
}

if ($TestSlack) {
    Write-Log 'TEST: posting a test message with map to Slack...'
    $withImage = Send-Alert (":test_tube: *TEST - $($cfg.SiteName) alarm monitor*`n" +
                "This is a test post. Serious alarms unprocessed for $($cfg.ThresholdMinutes)+ min will look like this, with a live map.")
    if ($withImage) { Write-Log 'TEST: posted with map image - check the channel'; exit 0 }
    Write-Log 'TEST: posted TEXT ONLY - map image failed (see lines above)'
    exit 2
}

Write-Log "Starting monitor for $($cfg.SiteName) ($base) - threshold $($cfg.ThresholdMinutes) min, poll $($cfg.PollSeconds)s"
$alerted      = Load-State   # id -> info for alarms we have already posted to Slack
$failCount    = 0
$offlineSent  = $false

while ($true) {
    try {
        if (-not $script:session) { Connect-Rms }
        $open    = Get-SeriousEvents '0'
        $openIds = @{}
        $now     = Get-Date

        foreach ($ev in $open) {
            $id = [string]$ev.id
            $openIds[$id] = $true
            $started = ConvertFrom-EpochMs $ev.createTimeL
            if (-not $started) { continue }
            $age = $now - $started
            if ($age.TotalMinutes -ge $cfg.ThresholdMinutes -and -not $alerted.ContainsKey($id)) {
                $what = Get-Friendly $ev.eventContent
                $obj  = $ev.eventObj
                $msg  = ":rotating_light: *SERIOUS ALARM - $($cfg.SiteName)*`n" +
                        "*$what*  (object: $obj)`n" +
                        "Unprocessed for $(Format-Duration $age) - since $($started.ToString('h:mm tt'))`n" +
                        "RMS: $base"
                $null = Send-Alert $msg
                $alerted[$id] = [pscustomobject]@{ started = $ev.createTimeL; what = $what; obj = $obj }
                Save-State $alerted
                Write-Log "ALERT sent for id=$id ($what, $obj), age $(Format-Duration $age)"
            }
        }

        # Anything we alerted on that is no longer unprocessed -> resolved
        foreach ($id in @($alerted.Keys)) {
            if ($openIds.ContainsKey($id)) { continue }
            $info     = $alerted[$id]
            $started  = ConvertFrom-EpochMs $info.started
            $finished = $null
            $done = Get-SeriousEvents '1' | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
            if ($done) { $finished = ConvertFrom-EpochMs $done.finishTimeL }
            if (-not $finished) { $finished = $now }
            $msg = ":white_check_mark: *RESOLVED - $($cfg.SiteName)*`n" +
                   "*$($info.what)*  (object: $($info.obj))`n" +
                   "Processed at $($finished.ToString('h:mm tt')) - total down $(Format-Duration ($finished - $started))"
            Send-Slack $msg
            $alerted.Remove($id)
            Save-State $alerted
            Write-Log "RESOLVED sent for id=$id"
        }

        if ($offlineSent) {
            Send-Slack ":large_green_circle: Alarm monitor for $($cfg.SiteName) is reconnected to RMS."
            $offlineSent = $false
        }
        $failCount = 0
        Send-Heartbeat
        if ($TestOnce) {
            Write-Log "TEST: $($open.Count) Serious alarm(s) currently unprocessed"
            $recent = Get-SeriousEvents '1' | Select-Object -First 5
            foreach ($ev in $recent) {
                Write-Log ("TEST: processed id={0}  {1}  obj={2}  {3} -> {4}" -f $ev.id, (Get-Friendly $ev.eventContent), $ev.eventObj,
                    (ConvertFrom-EpochMs $ev.createTimeL), (ConvertFrom-EpochMs $ev.finishTimeL))
            }
            break
        }
    }
    catch {
        $failCount++
        $script:session = $null
        Write-Log "ERROR ($failCount): $($_.Exception.Message)"
        if ($failCount -ge $cfg.OfflineAlertAfterFailures -and -not $offlineSent) {
            try {
                Send-Slack ":warning: Alarm monitor for $($cfg.SiteName) cannot reach RMS ($base) - E-stop alerts are NOT being checked. Last error: $($_.Exception.Message)"
                $offlineSent = $true
            } catch { Write-Log "Slack send failed: $($_.Exception.Message)" }
        }
        if ($TestOnce) { exit 1 }
    }
    Start-Sleep -Seconds $cfg.PollSeconds
}
