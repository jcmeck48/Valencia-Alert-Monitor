<#
  Live RMS map screenshot via headless Microsoft Edge (DevTools protocol).
  Dot-sourced by SeriousAlarmMonitor.ps1. Nothing to install - uses the Edge that ships with Windows.
#>

function Get-EdgePath {
    foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                     "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw 'Microsoft Edge (msedge.exe) not found'
}

function Receive-WsText($ws, [int]$timeoutMs) {
    $buf = New-Object byte[] 262144
    $ms  = New-Object IO.MemoryStream
    do {
        $seg = New-Object 'ArraySegment[byte]' -ArgumentList @(, $buf)
        $t = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        if (-not $t.Wait($timeoutMs)) { throw 'DevTools receive timeout' }
        $ms.Write($buf, 0, $t.Result.Count)
    } while (-not $t.Result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Invoke-Cdp($cdp, [string]$method, $params = @{}, [int]$timeoutMs = 30000) {
    $cdp.Id++
    $id  = $cdp.Id
    $msg = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object 'ArraySegment[byte]' -ArgumentList @(, $bytes)
    $cdp.Ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(10000) | Out-Null
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $text = Receive-WsText $cdp.Ws $timeoutMs
        if ($text -notmatch ('"id":' + $id + '[,}]')) { continue }   # skip events / other replies
        $r = $text | ConvertFrom-Json
        if ($r.error) { throw "DevTools $method failed: $($r.error.message)" }
        return $r.result
    }
    throw "DevTools $method timeout"
}

function Invoke-CdpEval($cdp, [string]$expr) {
    $r = Invoke-Cdp $cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
    return $r.result.value
}

function Wait-Until([scriptblock]$test, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $v = $null
        try { $v = & $test } catch {}   # page may be mid-navigation
        if ($v) { return $v }
        Start-Sleep -Milliseconds 750
    }
    return $null
}

# JS: fill the GSS login form (skips read-only inputs like the auth-method dropdown) and click Sign in
$script:LoginJs = @'
(function (u, p) {
  const pw = document.querySelector('input[type=password]');
  if (!pw) return 'no-password-field';
  const inputs = [...document.querySelectorAll('input')].filter(i =>
    i !== pw && !i.readOnly && i.type !== 'hidden' && i.type !== 'checkbox' && i.offsetParent &&
    (i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING));
  const user = inputs[inputs.length - 1];
  if (!user) return 'no-username-field';
  const set = (el, v) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  set(user, u); set(pw, p);
  const btn = [...document.querySelectorAll('button')].find(b => /sign\s*in|log\s*in|登录/i.test(b.innerText));
  if (!btn) return 'no-sign-in-button';
  btn.click();
  return 'ok';
})(__U__, __P__)
'@

# JS: returns the map iframe's rectangle once its canvas has rendered, else null
$script:MapReadyJs = @'
(function () {
  const f = document.querySelector('iframe');
  if (!f) return null;
  try {
    if (!f.contentDocument.querySelector('canvas')) return null;
  } catch (e) { return null; }
  const r = f.getBoundingClientRect();
  if (r.width < 200 || r.height < 200) return null;
  return JSON.stringify({ x: r.x, y: r.y, w: r.width, h: r.height });
})()
'@

function Get-RmsMapSnapshot {
    param(
        [string]$BaseUrl, [string]$Username, [string]$Password,
        [string]$OutFile, [string]$WorkDir,
        [string]$MapPath = '/static/mantis/#/monitor/map',
        [int]$SettleSeconds = 12, [int]$Port = 9333, [int]$Width = 1920, [int]$Height = 1080
    )
    # Kept between runs so the RMS session is usually still valid. Short path: Edge dislikes very long profile paths.
    $profileDir = Join-Path $env:ProgramData ('RMSMonitor\edge-' + (($BaseUrl -replace '^https?://', '') -replace '\W', '_'))
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $edgeArgs = @('--headless=new', "--remote-debugging-port=$Port", "--user-data-dir=`"$profileDir`"",
                  "--window-size=$Width,$Height", '--no-first-run', '--no-default-browser-check',
                  '--disable-extensions', '--hide-scrollbars', 'about:blank')
    $proc = Start-Process -FilePath (Get-EdgePath) -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
    $cdp  = $null
    try {
        $wsUrl = Wait-Until {
            try {
                $pages = @(Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 3)   # @() so PS 5.1 enumerates the array
                ($pages | ForEach-Object { $_ } | Where-Object { $_.type -eq 'page' } | Select-Object -First 1).webSocketDebuggerUrl
            } catch { $null }
        } 20
        if (-not $wsUrl) { throw 'Edge DevTools did not start' }

        $ws = New-Object Net.WebSockets.ClientWebSocket
        if (-not $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait(10000)) { throw 'DevTools connect timeout' }
        $cdp = [pscustomobject]@{ Ws = $ws; Id = 0 }
        Invoke-Cdp $cdp 'Emulation.setDeviceMetricsOverride' @{ width = $Width; height = $Height; deviceScaleFactor = 1; mobile = $false } | Out-Null

        $mapUrl = $BaseUrl.TrimEnd('/') + $MapPath
        Invoke-Cdp $cdp 'Page.navigate' @{ url = $mapUrl } | Out-Null

        # Either the map loads (session still valid) or we land on the login page
        $where = Wait-Until {
            $href = Invoke-CdpEval $cdp 'location.href'
            if ($href -match '/login') { if (Invoke-CdpEval $cdp "!!document.querySelector('input[type=password]')") { 'login' } }
            elseif (Invoke-CdpEval $cdp $script:MapReadyJs) { 'map' }
        } 45
        if (-not $where) { throw 'RMS page did not load (neither map nor login page)' }

        if ($where -eq 'login') {
            $js = $script:LoginJs.Replace('__U__', ($Username | ConvertTo-Json)).Replace('__P__', ($Password | ConvertTo-Json))
            $res = Invoke-CdpEval $cdp $js
            if ($res -ne 'ok') { throw "Could not fill RMS login form: $res" }
            $left = Wait-Until { (Invoke-CdpEval $cdp 'location.href') -notmatch '/login' } 30
            if (-not $left) { throw 'RMS login did not complete (still on login page)' }
            Invoke-Cdp $cdp 'Page.navigate' @{ url = $mapUrl } | Out-Null
        }

        $rectJson = Wait-Until { Invoke-CdpEval $cdp $script:MapReadyJs } 45
        if (-not $rectJson) { throw 'Map view did not render' }
        Start-Sleep -Seconds $SettleSeconds          # let robots / map tiles finish drawing
        $rectJson = Invoke-CdpEval $cdp $script:MapReadyJs
        $r = $rectJson | ConvertFrom-Json

        $shot = Invoke-Cdp $cdp 'Page.captureScreenshot' @{
            format = 'png'
            clip   = @{ x = [double]$r.x; y = [double]$r.y; width = [double]$r.w; height = [double]$r.h; scale = 1 }
        } 60000
        [IO.File]::WriteAllBytes($OutFile, [Convert]::FromBase64String($shot.data))
        return $OutFile
    }
    finally {
        if ($cdp) { try { Invoke-Cdp $cdp 'Browser.close' @{} 5000 | Out-Null } catch {} ; try { $cdp.Ws.Dispose() } catch {} }
        Start-Sleep -Milliseconds 500
        # Clean up any Edge processes that belong to our private profile (never touches the user's own Edge)
        $needle = [regex]::Escape($profileDir)
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $needle } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
    }
}
