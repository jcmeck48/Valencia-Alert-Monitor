# Run once per hub PC, from an elevated PowerShell, in the folder holding the script + config.json.
# Registers a scheduled task that starts the monitor at boot and restarts it if it dies.
#
# The task runs as a normal Windows account (you'll be asked which one and its password), because the
# hidden Edge window used for floor E-stop detection and map screenshots won't start under SYSTEM.
# It still runs at boot whether or not anyone is logged in. Windows stores the password securely.
#   -LoggedInUser : run as the account running this installer, only while it is logged in. No password
#                   needed - use this for accounts without a password (e.g. an auto-login hub account).
#   -RunAsSystem  : old behaviour (SYSTEM account) - floor E-stop detection and map images will NOT work
param([switch]$RunAsSystem, [switch]$LoggedInUser, [string]$User)

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

# Register first; the running copy (if any) is only stopped once the new task registered OK,
# so a failed install never leaves the site unmonitored.
try {
    if ($RunAsSystem) {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        $who = 'SYSTEM'
    } elseif ($LoggedInUser) {
        $acct = if ($User) { $User } else { "$env:USERDOMAIN\$env:USERNAME" }
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $acct
        $principal = New-ScheduledTaskPrincipal -UserId $acct -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        $who = "$acct (only while logged in)"
    } else {
        Write-Host "`nWhich Windows account should the monitor run as?" -ForegroundColor Cyan
        Write-Host 'It must have a password and read/write access to this folder (an admin account like hradmin works).'
        Write-Host 'Account has no password? Cancel and re-run with -LoggedInUser instead.'
        $cred = Get-Credential -Message "Windows account for '$name' (e.g. $env:COMPUTERNAME\username)"
        if (-not $cred) { Write-Host 'Cancelled - existing task left unchanged.' -ForegroundColor Yellow; exit 1 }
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings `
            -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
        $who = $cred.UserName
    }
} catch {
    Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Message -match 'password is incorrect') {
        Write-Host 'Wrong password - or the account has NO password (Windows won''t accept blank passwords for background tasks).' -ForegroundColor Yellow
        Write-Host 'Use an account with a password (e.g. hradmin), or re-run with -LoggedInUser.' -ForegroundColor Yellow
    }
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue   # make sure the old copy is still running
        Write-Host 'The existing monitor task was left in place and is running.' -ForegroundColor Yellow
    }
    exit 1
}

Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue   # stop old instance, start with new settings
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $name
$state = (Get-ScheduledTask -TaskName $name).State
Write-Host "Installed '$name' (runs as $who) - state: $state" -ForegroundColor Green
Write-Host "Log: $(Join-Path $dir "monitor-$site.log")"
