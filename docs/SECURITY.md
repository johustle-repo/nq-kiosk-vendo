# Security model and known limitations

## What is protected, and how

| Threat | Mitigation |
|---|---|
| Customer opens Settings / other apps / notifications | Device Owner + lock task allowlist; Home/Recents limited to approved apps; status bar disabled; `BLOCK_ACTIVITY_START_IN_TASK`; user restrictions. |
| Customer keeps using an app after time runs out | Native foreground service revokes the allowlist at expiry; Android closes the app's task. Watchdog + fail-closed `onDestroy`. |
| Fake "coin controller" on the Wi-Fi grants time | Status replies are HMAC-SHA256 signed with a 32-byte key shared at pairing, bound to a fresh 128-bit nonce, the paired device id and a monotonic uptime. |
| Replaying old controller replies | Nonce must match the request; uptime must increase within a boot. |
| Network request that adds time | None exists. Only accepted coin pulses add time. The cloud never sends time. |
| Simulated coins on a production kiosk | Rejected natively, buttons hidden. |
| Stale cloud/phone data granting access | Phone never persists remaining time; boot restricts first; cloud status is not an input to access decisions. |
| Stolen device credential | Per-device tokens, hashed at rest, revocable; type-bound (phone vs controller); ownership enforced on every call. |
| Dashboard brute force / CSRF / XSS / SQLi | Argon2id/bcrypt, per-user + per-IP rate limits, `SameSite=Strict` HttpOnly Secure cookie, session regeneration and idle/absolute timeouts, CSRF tokens on every POST, output escaping + strict CSP, prepared statements only. |
| Admin PIN guessing on the phone | PBKDF2-HMAC-SHA256 (60k iterations, random salt); exponential lockout after 4 failures that survives app kills and reboots; one-time recovery code. |
| Secrets on the phone | Controller key, cloud token and PIN hashes are encrypted with an Android Keystore AES-GCM key; `allowBackup=false` + data-extraction rules exclude them from backup/transfer. Nothing secret is in Flutter assets or logs. |
| Secrets on the server | `.env` outside the web root, denied by `.htaccess`, excluded from the package and from source control. |
| ESP8266 → cloud MITM | BearSSL with ISRG root trust anchors, NTP-validated time; `setInsecure()` is never used. |

## Local HTTP — honest limitations

The phone ↔ ESP8266 link is **plain HTTP on the shop Wi-Fi** (TLS on the
ESP8266 server side would cost too much RAM/CPU). Consequences:

* **Integrity/authenticity: protected** by HMAC (see above).
* **Confidentiality: none.** Anyone on the same Wi-Fi can read remaining time
  and pairing traffic.
* **Pairing key exposure**: the 32-byte key is sent once, in cleartext, during
  the 2-minute pairing window that requires physical access to the controller's
  button. An attacker sniffing the Wi-Fi *at that moment* could learn the key and
  later forge status replies. Mitigations: pair on a trusted network (or a
  temporary phone hotspot), use WPA2/WPA3 with a strong password, put the kiosk
  on a separate SSID/VLAN from customers, re-pair if in doubt.
* **Denial of service**: anyone on the LAN can block or flood the controller; the
  phone then hits the connection-loss timeout and **fails closed** (no access).

### Android cleartext policy

`network_security_config.xml` disables cleartext traffic for the whole app.
The controller's address is entered at run time and is an IP literal, which the
static config file cannot express narrowly. So the controller is reached through
`LocalHttp`, a minimal socket client that **refuses anything other than private
(RFC 1918) or link-local IPv4 literals** — it cannot send cleartext to the
internet. The cloud uses `HttpsURLConnection` with the system trust store.

## Kiosk escape paths that remain possible

* **Hardware recovery mode / factory reset** with the volume + power keys works
  on most phones regardless of policy (data is wiped; FRP does not apply without
  a Google account). Physically secure the phone and its buttons.
* **USB debugging** stays enabled by default so you can recover a locked kiosk.
  Turn on *Admin → Security → Disable USB debugging in production* only after
  testing, and cover the USB port.
* **Approved apps** can do whatever they normally do (browse the web, share,
  open their own settings). Approve only apps you are comfortable with. A web
  browser lets customers reach any website.
* **System launcher during paid time.** Recents and the gesture-navigation
  Home swipe are served by the stock launcher (`config_recentsComponentName`),
  so its package is on the lock task allowlist while a session is paid (never
  when unpaid). Normal navigation never shows its home screen, but an approved
  app that starts it by explicit component would show the stock app drawer.
  Lock task still blocks every unapproved app and Settings from there
  (verified on the Android 14 emulator); Home returns to the kiosk.
* **Accounts and app stores.** Production blocks adding accounts
  (`DISALLOW_MODIFY_ACCOUNTS`), so no customer's Google account can stay on the
  kiosk. Settings, the Play Store and package installers can never be approved
  (`RestrictedApps`), even from the dashboard. Android shows its "disabled by
  your admin" explanation through Settings, which stays blocked, so an approved
  app that tries to sign in shows "Settings is not available". Do not approve
  apps that need an account (e.g. Gmail).
* **Vendor (HiOS) behaviour** — some OEM system dialogs or gestures may behave
  differently under lock task. This must be verified on the TECNO phone; see
  `PHYSICAL_TEST_CHECKLIST.md`.

## Not production-ready until

Physical tests on the TECNO Spark 30C have passed, the APK is signed with a
release key you control, and the backend has been deployed and verified.
