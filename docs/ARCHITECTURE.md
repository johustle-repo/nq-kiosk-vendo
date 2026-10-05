# Architecture and behaviour

```
                                                         ┌──▶ Tablet 1 ┐
 Coin slot ──pulses──▶ ESP8266 coin box ◀──signed status─┼──▶ Tablet 2 ├ Android kiosk tablets (up to 4)
 (Allan, active-low)   • 4 authoritative timers  (LAN)   ├──▶ Tablet 3 │ • Flutter UI, Kotlin service
                       • held coins, selection           └──▶ Tablet 4 ┘ • Device Owner + lock task
                       • 20x4 LCD, event buffer                    │
                              │  poll ~2 s, sync 15 s              │ heartbeat 30 s
                              └──── outbound HTTPS ──▶ Hostinger ◀─┘
                                                       Laravel + MySQL: dashboard + /api/v1
                                                              ▲
                                             attendant (phone/PC browser): "next coins → Tablet 2"
```

## One coin box, several tablets

1. The attendant clicks **Select for next coins** on a tablet card in the
   dashboard. The coin box picks it up on its next poll (~2 s): the LCD shows
   `Insert: Tab 2` and that tablet shows a green **Tablet 2** badge
   ("The coin box is ready…").
2. Coins go to the selected tablet. The selection lasts 90 s and each coin
   extends it, so a forgotten selection cannot send a later customer's coins to
   the wrong tablet.
3. A coin inserted with **no** selection is **held** (LCD `Held: ₱5 ask staff`,
   dashboard *Held coins*); the attendant gives it to a tablet with one click.
4. With exactly one tablet paired there is nothing to choose: coins go straight
   to it (single-tablet kiosks need no attendant).
5. Internet down: the dashboard cannot reach the box, but a short press on the
   FLASH button (inside the locked box) cycles the selection; tablets keep
   working over the LAN.
6. The dashboard can also **add free time** or **end** a tablet's session; these
   are audited commands applied by the coin box exactly once.

## Who decides what

| Concern | Authority | Notes |
|---|---|---|
| Paid time (per tablet) | **ESP8266** | Coins add time to the selected tablet. Audited dashboard commands (add time, assign held coins, end) are applied by the box itself; no LAN endpoint grants time. |
| Which tablet gets the next coins | **Attendant** (dashboard) | FLASH button as offline fallback; automatic with a single paired tablet. |
| Customer access on the phone | **Phone (native)** | `AccessPolicy` + Device Owner lock task allowlist. |
| Rates, allowed apps, loss timeout | **Cloud config** (versioned) | Also editable locally on the phone by the admin. |
| Records (events, sessions, audit) | **Cloud** | Events and status are never pushed back as time; only explicit commands are. |

## Android components (`android/app/src/main/kotlin/online/ebnleadgen/vendokiosk`)

| File | Role |
|---|---|
| `core/SessionTracker.kt` | Mirrors controller time with the monotonic clock; dedupes/ignores stale reports; detects boot changes. Pure Kotlin, unit tested. |
| `core/AccessPolicy.kt` | Single access decision (`Granted`/`Denied(reason)`); `DemoClock` refuses simulated credit outside demo. |
| `core/ControllerProtocol.kt` | HMAC signature verification, nonce/device checks, command MACs. |
| `core/LocalHttp.kt` | Minimal HTTP client restricted to private IPv4 literals. |
| `core/PinSecurity.kt` | PIN rules, PBKDF2 hashing, recovery codes, exponential lockout. |
| `service/KioskEngine.kt` | Worker thread: 500 ms tick, 1 s controller poll, 30 s cloud heartbeat, enforcement. |
| `service/KioskService.kt` | Foreground service (`connectedDevice`) hosting the engine. |
| `kiosk/KioskPolicy.kt` | All `DevicePolicyManager` calls (lock task, restrictions, persistent home). |
| `kiosk/Receivers.kt` | Boot receiver (restrict first, then start service) and watchdog alarm. |
| `data/KioskStore.kt` | Settings; secrets encrypted with an Android Keystore AES-GCM key. |
| `MainActivity.kt` | Flutter host; `MethodChannel vendo_kiosk/native`, `EventChannel vendo_kiosk/state`. |

Flutter (`lib/`) is UI only. It renders native state snapshots and sends
commands; it holds no secrets, makes no network calls and keeps no timers that
matter for enforcement (a Dart timer does not run reliably while another app
is in front).

## How enforcement works (production)

1. The app is **Device Owner**. `KioskHome` (an activity-alias with the HOME
   category) is enabled and set as the persistent preferred home activity.
2. `MainActivity` has `lockTaskMode="if_whitelisted"`, so it runs in **lock
   task mode**. The lock task allowlist normally contains only the kiosk.
3. When the controller reports paid time, `KioskPolicy.setPaidAccess(apps)`
   adds the administrator-approved packages to the allowlist and enables the
   Home + Overview buttons. Customers can switch between approved apps and
   return to the launcher with Home. Anything else cannot be started.
   `LOCK_TASK_FEATURE_BLOCK_ACTIVITY_START_IN_TASK` (Android 11+) stops approved
   apps from opening non-approved screens (e.g. Settings) inside their own task.
4. At expiry (or controller loss), `setPaidAccess(null)` removes the customer
   apps from the allowlist. Android finishes their tasks and returns to the
   kiosk task — **even while a customer app is in the foreground**. This runs in
   the foreground service, not in Flutter.
5. Notifications, the status bar, global actions (power menu), keyguard and
   Settings are unavailable in lock task; extra user restrictions block factory
   reset from Settings, safe boot, adding users, USB file transfer, unknown
   sources, overlays (`DISALLOW_CREATE_WINDOWS`) and date/time changes.

Accessibility services and overlays are **not** used. Hiding launcher buttons
is not relied on.

## Timing model

* Phone time base: `SystemClock.elapsedRealtime()` (monotonic, unaffected by
  wall-clock changes). Controller time base: `millis()` (64-bit wrapped).
* The phone polls the controller every second with a new random nonce. Each
  verified report sets a baseline; between reports the phone counts **down**
  only. Polls, retries and reconnects therefore cannot add time.
* Displayed/enforced remaining time = `reported_remaining − age_of_report`.
  The phone never persists remaining time; nothing stale is restored.

## Defined behaviours

| Situation | Behaviour |
|---|---|
| **Additional coins** | Controller extends the running session (`end += pulses × rate`), increments `seq`; phone sees a higher `seq` and shows "+N min added". |
| **Expiry while another app is open** | Phone estimate reaches 0 → service revokes the allowlist → customer app closes → payment screen. The controller independently logs an `expire` event. |
| **Local network loss** (phone ↔ controller) | Phone keeps counting down the last verified time. If no verified report arrives within the **connection-loss timeout** (default 30 s, configurable 5–600 s), production denies access and returns to payment ("Coin controller disconnected"). The controller keeps counting; when the link returns the phone adopts the controller's current value. |
| **Internet / cloud outage** | No effect on access. Controller buffers up to 48 events; phone shows "Cloud: offline" separately from the controller indicator. |
| **Controller restart** | New `boot_id`. With `RESUME_AFTER_RESTART=1` (default) the controller restores the last checkpoint (≤ 60 s old; time spent powered off is not deducted). The phone replaces its baseline with the fresh report; if the controller restored 0, access ends. |
| **Phone restart** | Boot receiver immediately restricts the allowlist to the kiosk, starts the service; access is granted again only after a fresh signed report. |
| **Service killed by the OS** | `onDestroy` revokes access; a 1-minute watchdog alarm revokes access and restarts the service if it is not ticking. |
| **Device Owner missing in production** | Access denied with `not_device_owner`; the UI shows an error. No fallback to demo. |
| **Simulated coins in production** | Rejected natively (`simulated_credit_rejected`); the buttons are not shown. |
| **Event buffer overflow** (controller offline from cloud for long) | Oldest unsent event is dropped, `dropped_events` is incremented and shown on the dashboard. Local paid time is never affected. |
| **Retried cloud uploads** | Idempotent on `(device, boot_id, seq)`. |
| **Config change** | New immutable version; devices apply on next sync and report `config_version_applied`. New rates apply to future coins only. |
| **Stale cloud data** | The cloud never sends time to devices; status reports older (lower uptime, same boot) than the stored one are ignored; devices not heard from within 90 s (controller) / 120 s (phone) show **OFFLINE**. |

## Data persistence

| Where | What | When written |
|---|---|---|
| Phone SharedPreferences | mode, controller address/id, **tablet number**, allowed apps, loss timeout, cloud config version | on change |
| Phone (Keystore-encrypted) | controller HMAC key, cloud token, PIN + recovery hashes | on change |
| ESP8266 LittleFS `/settings.txt` | Wi-Fi, cloud token, a pairing key per tablet, rate | on change only |
| ESP8266 LittleFS `/session.txt` | each tablet's remaining seconds, held coins, last 16 applied command ids | each coin, expiry, command, and every 60 s while running |
| ESP8266 RAM | unsent events (48 max) | lost on power loss (documented) |
| MySQL | sites, devices, events, per-tablet sessions, status, config versions, commands, audit | on each request |
