# Run once per hub PC, from an elevated PowerShell, in the folder holding the script + config.json.
# Registers a scheduled task that starts the monitor at boot and restarts it if it dies.
#
# The task runs as a normal Windows account (you'll be asked which one and its password), because the
# hidden Edge window used for floor E-stop detection and map screenshots won't start under SYSTEM.
# It still runs at boot whether or not anyone is logged in. Windows stores the password securely.
#   -RunAsSystem : old behaviour (SYSTEM account) - floor E-stop detection and map images will NOT work
param([switch]$RunAsSystem)

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'This must run as Administrator: right-click PowerShell > Run as administrator, then run it again.' -ForegroundColor Red
    exit 1
}

$dir    = $PSScriptRoot
$script = Join-Path $dir 'SeriousAlarmMonitor.ps1'
$config = Join-Path $dir 'config.json'
$site   = ((Get-Content $config -Raw | ConvertFrom-Json).SiteName -replace '\W', '')
$name   = "RMS Serious Alarm Monitor - $site"

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -ConfigPath `"$config`"" `
    -WorkingDirectory $dir
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# Stop any running copy first so the new settings take over cleanly
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
}

if ($RunAsSystem) {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    $who = 'SYSTEM'
} else {
    Write-Host "`nWhich Windows account should the monitor run as?" -ForegroundColor Cyan
    Write-Host 'Use the hub PC''s normal account (e.g. the one that stays logged in on this PC). It needs read/write access to this folder.'
    $cred = Get-Credential -Message "Windows account for '$name' (e.g. $env:COMPUTERNAME\username or DOMAIN\username)"
    if (-not $cred) { Write-Host 'Cancelled.' -ForegroundColor Yellow; exit 1 }
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings `
        -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
    $who = $cred.UserName
}

Start-ScheduledTask -TaskName $name
$state = (Get-ScheduledTask -TaskName $name).State
Write-Host "Installed '$name' (runs as $who) - state: $state" -ForegroundColor Green
Write-Host "Log: $(Join-Path $dir "monitor-$site.log")"
