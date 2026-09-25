# Run once per hub PC, from an elevated PowerShell, in the folder holding the script + config.json.
# Registers a scheduled task that starts the monitor at boot and restarts it if it dies.
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
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $name
Write-Host "Installed and started '$name'. Log: $(Join-Path $dir "monitor-$site.log")"
