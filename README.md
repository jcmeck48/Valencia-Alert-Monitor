# RMS Serious Alarm Monitor — Valencia

Watches the Geek+ RMS at **http://10.236.101.? (see config)** and posts to Slack **#hpy-valencia-auto-go-live**:

- :rotating_light: **Alert** when a *Serious* alarm (e.g. a system emergency stop) stays **Unprocessed for 20+ minutes**, with a live screenshot of the RMS map attached
- :white_check_mark: **Resolved** when that same alarm is processed, with total downtime
- :warning: **Monitor offline** if it can't reach the RMS for 10 minutes (and a follow-up when it reconnects)

It checks once a minute, runs in the background as a Windows Scheduled Task, starts automatically at boot, and restarts itself if it crashes. No one needs to be logged in.

---

## Files

| File | What it is |
|---|---|
| `SeriousAlarmMonitor.ps1` | The monitor |
| `MapSnapshot.ps1` | Takes the map screenshot using a hidden Edge window |
| `Install-Monitor.ps1` | Sets it up to run automatically (run once, as admin) |
| `Test-Setup.ps1` | Checks everything and prints PASS / FAIL |
| `config.json` | This site's settings |

Created while running: `monitor-Valencia.log` (activity log), `state-Valencia.json` (alarms already alerted on), `map-latest.png` / `map-test.png`.

---

## First-time setup (on the Valencia hub PC)

1. **Copy** the `RMSMonitor` folder to `C:\RMSMonitor`.
   Keep it there — the background task runs from this folder.

2. **Fill in `config.json`** (open with Notepad):
   - `BotToken` — paste the same `xoxb-...` token used at Shoemakersville
   - `RmsBaseUrl` — replace `10.236.101.FIX_ME` with the full Valencia RMS IP (4 numbers, e.g. `http://10.236.101.25`)
3. **Invite the bot** to the Slack channel: in **#hpy-valencia-auto-go-live** type `/invite @<bot name>`.

4. **Run the test** — open **PowerShell as administrator** (Start → type PowerShell → right-click → *Run as administrator*):
   ```
   cd C:\RMSMonitor
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Setup.ps1
   ```
   This posts **one** test message to the channel. Use `-SkipSlack` on the end to skip that.

5. **Install** once every step shows PASS (a WARN on "Background task" is expected before installing):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Monitor.ps1
   ```

6. **Check it started:** open `monitor-Valencia.log` — you should see `Starting monitor…` and `Logged in to RMS`.

7. **Power settings:** Settings → System → Power → set sleep to **Never**. A sleeping PC doesn't monitor.

---

## What the test checks

| Step | PASS means | If it fails |
|---|---|---|
| Files | All 4 scripts + config are in the folder | Re-copy the folder |
| Config | Valid, no placeholders, channel ID looks right | Fix `config.json` — `ChannelId` must be an ID (`C07…`), not a name |
| Network | This PC can reach the RMS | Wrong IP, or this PC isn't on the site network |
| RMS login + alarms | Logged in and read the Serious alarm list | Wrong username/password, or a different RMS version — send the output to whoever maintains this |
| Map screenshot | `map-test.png` saved — open it and check it shows the map | Alerts still work, just without the picture. If robots are missing, raise `SettleSeconds` |
| Slack post | Test message **with map** appeared in the channel | **WARN (text only):** add the `files:write` scope to the Slack app and reinstall. **FAIL:** check `BotToken` and that the bot is invited |
| Background task | Installed and Running | Run `Install-Monitor.ps1` as admin |

You can re-run the test at any time — it doesn't interfere with the running monitor.

---

## Start / stop / restart

Admin PowerShell:
```
Stop-ScheduledTask  -TaskName "RMS Serious Alarm Monitor - Valencia"
Start-ScheduledTask -TaskName "RMS Serious Alarm Monitor - Valencia"
Get-ScheduledTask   -TaskName "RMS Serious Alarm Monitor - Valencia" | Select-Object State
```
Or: **Task Scheduler** → *Task Scheduler Library* → right-click the task → **End** / **Run** / **Disable**.

## Changing settings

Edit `config.json`, save, then **restart** (Stop, then Start). The monitor only reads the config when it starts. Check the newest `Starting monitor…` line in the log to confirm the new values.

| Setting | Meaning | Default |
|---|---|---|
| `ThresholdMinutes` | Minutes a Serious alarm stays unprocessed before alerting | 20 |
| `PollSeconds` | How often it checks the RMS | 60 |
| `Slack.ChannelId` | Channel to post in (must be the ID) | C07NK1HFQHK |
| `OfflineAlertAfterFailures` | Failed checks in a row before the "monitor offline" warning | 10 |
| `MapSnapshot.Enabled` | Attach the map screenshot | true |
| `MapSnapshot.SettleSeconds` | Seconds to let the map draw before the screenshot | 12 |

Keep numbers without quotes and don't delete commas — if `config.json` breaks, the monitor won't start.

## Troubleshooting

- **Log shows `missing_scope`** → Slack app needs `files:write`; add it and click *Reinstall to Workspace*.
- **Log shows `not_in_channel` / `channel_not_found`** → invite the bot to the channel; check `ChannelId`.
- **Log shows `RMS login failed`** → check `Username` / `Password` in `config.json`.
- **Alerts arrive without the map image, but `Test-Setup` screenshot passed** → the hidden Edge window may not render under the background (SYSTEM) account on this PC; ask for the monitor to be switched to run as the logged-in user.
- **Nothing in the log for hours** → normal; it only writes when something happens. Check the task State is *Running*.

---

## Dead-man's switch (alerts if this monitor itself goes down)

The monitor can't report its own death (PC off, frozen, task stopped). So after every successful check it pings **healthchecks.io**; if the pings stop, healthchecks.io posts to Slack.

**Setup (one time):**
1. Sign up at https://healthchecks.io (free plan).
2. **Integrations** → add **Slack** → choose **#hpy-valencia-auto-go-live**.
3. **Add Check** → name it `Valencia RMS monitor` → **Period: 1 minute**, **Grace: 5 minutes** → make sure the Slack integration is ticked for this check.
4. Copy the check's ping URL (`https://hc-ping.com/...`) into `config.json`:
   ```
   "Heartbeat": { "PingUrl": "https://hc-ping.com/your-uuid" }
   ```
5. Run `Test-Setup.ps1` (Heartbeat should PASS), then **restart** the monitor.

The check turns green within a minute. If the monitor stops pinging for ~6 minutes you'll get a **DOWN** message in Slack, and an **UP** message when it recovers.
Leave `PingUrl` empty (`""`) to switch this off.

## Removing it

Admin PowerShell:
```
Unregister-ScheduledTask -TaskName "RMS Serious Alarm Monitor - Valencia" -Confirm:$false
```
Then delete `C:\RMSMonitor`.
