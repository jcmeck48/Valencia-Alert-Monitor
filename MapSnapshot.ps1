<#
  Live RMS map via a hidden Microsoft Edge window (DevTools protocol).
  Dot-sourced by SeriousAlarmMonitor.ps1. Nothing to install - uses the Edge that ships with Windows.

  One Edge window is kept open on the RMS map page and reused for:
    - Get-RmsSystemState      : reads the map's systemState ("RUNNING" / "STOP") - catches floor E-stops
                                that never appear in the RMS alarm list
    - Save-RmsMapScreenshot   : screenshot of the map panel for Slack alerts
  $opts = @{ BaseUrl; Username; Password; MapPath; SettleSeconds; Width; Height }
#>

$script:Rb = $null   # the open browser: @{ Proc; Cdp; ProfileDir; LoadedAt }

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

# JS: the map page's live system state (same value that drives the "system emergency stop" banner)
$script:StateJs = @'
(function () {
  try {
    const f = document.querySelector('iframe');
    if (!f) return null;
    const d = f.contentDocument;
    let host = [d.body, d.querySelector('#app')].find(e => e && e.__vue_app__);   // RMS mounts on <body>
    if (!host) host = [...d.querySelectorAll('*')].find(e => e.__vue_app__);
    if (!host) return null;
    const pinia = host.__vue_app__.config.globalProperties.$pinia;
    const s = pinia && pinia.state.value.map2dStore;
    if (!s || !s.mapConfig || !s.mapConfig.systemState) return null;
    return JSON.stringify({ state: s.mapConfig.systemState, running: s.mapConfig.systemRunning });
  } catch (e) { return null; }
})()
'@

function Stop-RmsBrowser {
    if ($script:Rb) {
        try { Invoke-Cdp $script:Rb.Cdp 'Browser.close' @{} 5000 | Out-Null } catch {}
        try { $script:Rb.Cdp.Ws.Dispose() } catch {}
        Start-Sleep -Milliseconds 500
        $dir = $script:Rb.ProfileDir
        $script:Rb = $null
    } else { $dir = $null }
    if ($dir) { Stop-EdgeForProfile $dir }
}

# Only ever touches Edge processes using our private profile - never the user's own Edge
function Stop-EdgeForProfile([string]$profileDir) {
    $needle = [regex]::Escape($profileDir)
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $needle } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
}

function Start-RmsBrowser($opts) {
    Stop-RmsBrowser
    # Kept between runs so the RMS session is usually still valid. Short path: Edge dislikes very long profile paths.
    # Per-user location, so a profile created by another account (e.g. SYSTEM) never blocks it.
    $profileDir = Join-Path $env:LOCALAPPDATA ('RMSMonitor\edge-' + (($opts.BaseUrl -replace '^https?://', '') -replace '\W', '_'))
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    Stop-EdgeForProfile $profileDir          # leftovers from a previous run hold the profile lock
    $portFile = Join-Path $profileDir 'DevToolsActivePort'
    Remove-Item $portFile -Force -ErrorAction SilentlyContinue

    $edgeArgs = @('--headless=new', '--remote-debugging-port=0', "--user-data-dir=`"$profileDir`"",
                  "--window-size=$($opts.Width),$($opts.Height)", '--no-first-run', '--no-default-browser-check',
                  '--disable-extensions', '--hide-scrollbars', '--enable-logging', '--v=0')
    # The Chromium sandbox often can't start under the SYSTEM account (background task)
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { $edgeArgs += @('--no-sandbox', '--disable-gpu-sandbox') }
    $edgeArgs += 'about:blank'
    $proc = Start-Process -FilePath (Get-EdgePath) -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden

    $wsUrl = Wait-Until {
        if (-not (Test-Path $portFile)) { return $null }
        $p = Get-Content $portFile -TotalCount 1
        if ($p -notmatch '^\d+$') { return $null }
        $pages = @(Invoke-RestMethod "http://127.0.0.1:$p/json/list" -TimeoutSec 3)   # @() so PS 5.1 enumerates the array
        ($pages | ForEach-Object { $_ } | Where-Object { $_.type -eq 'page' } | Select-Object -First 1).webSocketDebuggerUrl
    } 45
    if (-not $wsUrl) {
        $why = if ($proc.HasExited) { "Edge exited with code $($proc.ExitCode)" } else { 'Edge running but DevTools not answering' }
        $logTail = ''
        $dbg = Join-Path $profileDir 'chrome_debug.log'
        if (Test-Path $dbg) { $logTail = ' | edge log: ' + ((Get-Content $dbg -Tail 3) -join ' / ') }
        Stop-EdgeForProfile $profileDir
        throw "Edge DevTools did not start ($why, running as $([Environment]::UserName))$logTail"
    }

    $ws = New-Object Net.WebSockets.ClientWebSocket
    if (-not $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait(10000)) { Stop-EdgeForProfile $profileDir; throw 'DevTools connect timeout' }
    $cdp = [pscustomobject]@{ Ws = $ws; Id = 0 }
    $script:Rb = @{ Proc = $proc; Cdp = $cdp; ProfileDir = $profileDir; LoadedAt = $null }
    Invoke-Cdp $cdp 'Emulation.setDeviceMetricsOverride' @{ width = $opts.Width; height = $opts.Height; deviceScaleFactor = 1; mobile = $false } | Out-Null
    Open-RmsMap $opts
}

# (Re)load the map page, logging in if the session has expired
function Open-RmsMap($opts) {
    $cdp    = $script:Rb.Cdp
    $mapUrl = $opts.BaseUrl.TrimEnd('/') + $opts.MapPath
    Invoke-Cdp $cdp 'Page.navigate' @{ url = $mapUrl } | Out-Null

    $where = Wait-Until {
        $href = Invoke-CdpEval $cdp 'location.href'
        if ($href -match '/login') { if (Invoke-CdpEval $cdp "!!document.querySelector('input[type=password]')") { 'login' } }
        elseif (Invoke-CdpEval $cdp $script:MapReadyJs) { 'map' }
    } 45
    if (-not $where) { throw 'RMS page did not load (neither map nor login page)' }

    if ($where -eq 'login') {
        $js = $script:LoginJs.Replace('__U__', ($opts.Username | ConvertTo-Json)).Replace('__P__', ($opts.Password | ConvertTo-Json))
        $res = Invoke-CdpEval $cdp $js
        if ($res -ne 'ok') { throw "Could not fill RMS login form: $res" }
        $left = Wait-Until { (Invoke-CdpEval $cdp 'location.href') -notmatch '/login' } 30
        if (-not $left) { throw 'RMS login did not complete (still on login page)' }
        Invoke-Cdp $cdp 'Page.navigate' @{ url = $mapUrl } | Out-Null
    }

    if (-not (Wait-Until { Invoke-CdpEval $cdp $script:MapReadyJs } 45)) { throw 'Map view did not render' }
    Start-Sleep -Seconds $opts.SettleSeconds          # let robots / map tiles finish drawing
    $script:Rb.LoadedAt = Get-Date
}

# Start the browser if needed, restart it if it died, and refresh the page every few hours
function Use-RmsBrowser($opts) {
    $alive = $false
    if ($script:Rb) { try { $alive = ((Invoke-CdpEval $script:Rb.Cdp '1+1') -eq 2) } catch { $alive = $false } }
    if (-not $alive) { Start-RmsBrowser $opts; return }
    if (-not $script:Rb.LoadedAt -or ((Get-Date) - $script:Rb.LoadedAt).TotalHours -ge 6) { Open-RmsMap $opts }
}

function Get-RmsSystemState($opts) {
    Use-RmsBrowser $opts
    $json = Invoke-CdpEval $script:Rb.Cdp $script:StateJs
    if (-not $json) { Open-RmsMap $opts; $json = Invoke-CdpEval $script:Rb.Cdp $script:StateJs }   # logged out / page reset
    if (-not $json) { throw 'map page loaded but system state not found' }
    return ($json | ConvertFrom-Json)
}

function Save-RmsMapScreenshot($opts, [string]$OutFile) {
    Use-RmsBrowser $opts
    $rectJson = Invoke-CdpEval $script:Rb.Cdp $script:MapReadyJs
    if (-not $rectJson) { Open-RmsMap $opts; $rectJson = Invoke-CdpEval $script:Rb.Cdp $script:MapReadyJs }
    if (-not $rectJson) { throw 'Map view did not render' }
    $r = $rectJson | ConvertFrom-Json
    $shot = Invoke-Cdp $script:Rb.Cdp 'Page.captureScreenshot' @{
        format = 'png'
        clip   = @{ x = [double]$r.x; y = [double]$r.y; width = [double]$r.w; height = [double]$r.h; scale = 1 }
    } 60000
    [IO.File]::WriteAllBytes($OutFile, [Convert]::FromBase64String($shot.data))
    return $OutFile
}
