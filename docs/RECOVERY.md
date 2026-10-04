# Troubleshooting and recovery

## Administrator access to the kiosk

* Open admin settings: on the payment or paid screen, **tap the timer 7 times
  within 4 seconds**, then enter the PIN. Customers see no button or hint.
* Admin sessions lock after 5 minutes of inactivity and when you leave the
  settings screen.

### Forgot the PIN
On the PIN dialog tap **Forgot PIN?**, enter the 16-character recovery code
shown when the PIN was created, and choose a new PIN. A new recovery code is
issued — write it down. Wrong codes count toward the same lockout.

### Lost both PIN and recovery code
1. If USB debugging is still enabled (default) and this computer was authorised
   before, run:
   ```
   adb shell am broadcast -a online.ebnleadgen.vendokiosk.ADB_RECOVERY -n online.ebnleadgen.vendokiosk/.kiosk.AdbRecoveryReceiver
   ```
   This leaves lock task, removes the kiosk restrictions and deletes the PIN;
   the app opens its setup screen so you can create a new PIN. Device Owner,
   controller pairing and cloud enrollment are kept. (The receiver is protected
   by `android.permission.DUMP`, which only the adb shell/system hold.)
   Note: *Clear storage* in Settings and `adb shell pm clear` do **not** work for
   a Device Owner app — Android protects its data.
   `adb shell am task lock stop` alone also leaves lock task mode temporarily.
2. If USB debugging was disabled: the only path is a **factory reset from
   recovery mode** (power off; hold Power + Volume Up on most TECNO models;
   choose *Wipe data/factory reset*). **This erases the phone.** Then provision
   again (`DEVICE_OWNER_PROVISIONING.md`).

### Exit kiosk for maintenance
Admin → Kiosk mode → **Exit kiosk**. The phone becomes a normal phone (app stays
Device Owner, in demo mode). Re-enable production from the same screen.

## Common problems

| Symptom | Cause / fix |
|---|---|
| Screen is black / off | Normal: with no paid time the kiosk sleeps after the idle delay (Admin → System → Screen, default 1 min). Insert a coin to wake it; tap the dark screen 7 times for the admin PIN. Touches alone do not wake it. |
| Phone shows a lock screen after waking | Remove the PIN/pattern (Settings → Security → Screen lock → None). A swipe-only lock is dismissed automatically; production mode disables it via Device Owner. |
| "Coin controller: not paired" | Admin → Coin controller → pair (hold FLASH 3 s for the code). |
| "connecting…" forever | Wrong IP, phone on a different Wi-Fi/guest network with client isolation, or controller offline. Short-press FLASH to read the IP on the LCD; use a DHCP reservation. |
| "disconnected (Ns)" and customers locked out | Local link lost longer than the loss timeout. Check Wi-Fi signal and power at the controller. Access returns automatically when reports resume. |
| Pairing says "Wrong pairing code" / "Pairing is not open" | The code is valid for 2 minutes and 5 attempts; hold FLASH 3 s again. |
| After controller restart customers lost time | `RESUME_AFTER_RESTART` set to 0, or the session expired during the outage. |
| "Production mode requires … Device Owner" | Not provisioned. See `DEVICE_OWNER_PROVISIONING.md`. There is no automatic fallback. |
| Kiosk starts to the TECNO launcher after reboot | Production not enabled, or HiOS reset the default home. Open the app, Admin → Kiosk mode → check *policy problems*; report this in the physical test log. |
| "Keyguard: remove the screen lock" policy problem | A PIN/pattern lock is set; remove it in Settings (exit kiosk first). |
| App killed in the background (HiOS battery saver) | Expected to be prevented by the foreground service + Device Owner; if seen, add the app to HiOS *Auto-start* / *No restrictions* and record it in the test log. |
| "Cloud: offline" | Internet or Hostinger unreachable. Local operation continues. |
| "Cloud: credential revoked" | Device revoked in the dashboard → generate a new code and re-enroll. |
| Dashboard shows device OFFLINE but kiosk works | Cloud status is reporting only; check the device's internet access. |
| Controller LCD stuck on `WIFI SETUP MODE` | No/invalid Wi-Fi saved; connect to its access point and save Wi-Fi again. |
| Controller never reaches the cloud | Needs internet + correct time (NTP, UDP 123). Serial log at 115200 baud shows `[cloud]` errors. |
| Coins not counted / double counted | Check common ground, signal level (≤3.3 V), slot pulse speed; adjust `PULSE_*` values in `config.h`. |
| `/setup` says "Setup is disabled" | `SETUP_TOKEN` missing/short in `vendo_app/.env`. |
| Health returns 503 "configuration or database unavailable" | `.env` missing or wrong DB credentials; check the PHP error log in hPanel. |
| Locked out of dashboard login | Wait 15 minutes (rate limit). Lost password with SSH: `php vendo_app/bin/create-admin.php newadmin`. Without SSH: phpMyAdmin → run `UPDATE admins SET password_hash = '<hash>' WHERE username='…'` with a hash from `php -r "echo password_hash('NewLongPassword', PASSWORD_DEFAULT);"`. |

## Logs

* Phone: `adb logcat -s VendoKiosk` (no secrets are logged).
* Controller: USB serial at 115200 baud.
* Server: hPanel → Advanced → Error logs (`[vendo]` prefix); dashboard → Audit log.
