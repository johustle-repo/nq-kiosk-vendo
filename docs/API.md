# Vendo Kiosk API reference

One **site** = one coin box (ESP8266) shared by up to **4 tablets** ("stations"
1–4). There are two APIs:

1. **Cloud API** (`https://vendo-kiosk.ebnleadgen.online/api/v1/…`), the Laravel
   app in `dashboard/` on Hostinger. Devices call it **outbound** over HTTPS. It
   records events and status, hands out configuration, and carries the
   attendant's **selection** and **commands** to the coin box.
2. **Local controller API** (`http://<esp8266-ip>/api/v1/…`) on the ESP8266,
   used only by the paired tablets on the same Wi-Fi. The coin box is the
   authority for each tablet's paid time.

All timestamps are UTC. All JSON bodies are UTF-8.

---

## 1. Cloud API (`/api/v1`)

### Authentication

Each device has its **own** credential, issued once at enrollment:

```
Authorization: Bearer vkd_<16-hex public id>_<43-char secret>
```

If a host strips the `Authorization` header, `X-Device-Token: vkd_…` is
accepted instead. Only `SHA-256(secret)` is stored server-side. Credentials are
revocable per device from the dashboard. A coin box credential cannot call
tablet endpoints and vice-versa (`401`).

Errors always look like:

```json
{ "ok": false, "error": { "code": "unauthorized", "message": "Missing, invalid, revoked or wrong-type device token." } }
```

| HTTP | code | meaning |
|---|---|---|
| 401 | `unauthorized` | missing / bad / revoked / wrong-type token |
| 403 | `invalid_code`, `wrong_device_type` | enrollment rejected |
| 404 | `not_found` | unknown endpoint |
| 422 | `invalid_json`, `invalid_fields`, `unsupported_protocol`, `too_many_events` | validation |
| 429 | `rate_limited` | enrollment: 10/hour per IP; devices: 150/min per credential |
| 503 | — | health: DB down or migrations pending |

### `GET /api/v1/health`

No authentication.

```json
{ "ok": true, "service": "vendo-kiosk", "api_version": "v1", "backend_version": "2.0.0",
  "database": "ok", "pending_migrations": 0, "server_time": 1791095200 }
```

### `POST /api/v1/devices/enroll`

Redeems a **one-time** code from the dashboard (site page → *Enroll a device*).
Codes are single-use, typed (tablet vs coin box), expire after 30 minutes, and a
tablet code carries the tablet number.

```json
{ "device_type": "phone", "enrollment_code": "89KW4-8Y2MW", "name": "Kiosk tablet", "hardware_id": "…" }
```

Response `201` (the token is shown **once**):

```json
{ "ok": true, "device_id": "107d8de56f6a8918", "device_token": "vkd_107d8de56f6a8918_xbK…",
  "station": 2, "api_base": "https://vendo-kiosk.ebnleadgen.online/api/v1" }
```

### `POST /api/v1/controller/poll` (coin box → cloud, every ~2 s)

Fast channel for the attendant. Sent on the same kept-alive TLS connection as
sync and the `status.php` upload.

```json
{ "boot_id": "0a1b2c3d", "selected": 2, "selected_ttl_s": 74, "held_pulses": 5,
  "acks": [ { "id": 41, "result": "ok" } ] }
```

* `selected` / `selected_ttl_s` — where coins go right now (0 = held), as the
  coin box sees it (includes local FLASH-button choices).
* `acks` — commands applied since the last poll (`ok`, `not_running`,
  `nothing_held`, `bad_station`, …).

Response `200`:

```json
{
  "ok": true, "server_time": 1791095201,
  "selection": { "version": 7, "station": 3, "ttl_s": 90 },
  "commands": [
    { "id": 42, "type": "add_time", "station": 3, "seconds": 900 },
    { "id": 43, "type": "end_session", "station": 1, "seconds": 0 },
    { "id": 44, "type": "assign_held", "station": 4, "seconds": 0 }
  ]
}
```

* The coin box applies `selection` only when `version` changed (0 = cleared or
  expired). A selection lasts 90 s and each coin extends it on the box.
* Commands are re-sent until acknowledged; the coin box remembers the last 16
  applied ids (also across restarts) so a command is never applied twice.
* `add_time` is 60 s – 4 h; every command is written to the audit log with the
  administrator who issued it.

### `POST /api/v1/controller/sync` (coin box → cloud)

Every `sync_interval_s` (default 15 s) and ~3 s after a coin. Protocol **2**
(protocol 1 is still accepted and treated as tablet 1).

```json
{
  "protocol": 2, "boot_id": "0a1b2c3d", "uptime_ms": 60000, "fw_version": "2.0.0",
  "config_version_applied": 1,
  "status": {
    "session": "running", "remaining_s": 420, "seq": 9, "session_no": 1,
    "seconds_per_pulse": 240, "rate_version": 1, "wifi_rssi": -61, "free_heap": 21800,
    "buffered_events": 1, "dropped_events": 0, "held_pulses": 0,
    "stations": [
      { "station": 1, "session": "running", "remaining_s": 420, "session_no": 1, "paired": true, "phone_last_poll_age_s": 1 },
      { "station": 2, "session": "idle", "remaining_s": 0, "session_no": 0, "paired": true, "phone_last_poll_age_s": 1 }
    ]
  },
  "events": [
    { "seq": 9, "type": "credit", "station": 1, "session_no": 1, "pulses": 5, "seconds": 1200,
      "rate_version": 1, "remaining_after": 1200, "uptime_ms": 59000, "unix_time": 1791095140, "command_id": 0 }
  ]
}
```

Event types: `credit` (coins to the selected tablet), `held` (coins with no
tablet selected; `station` 0), `assign` (held coins given to a tablet),
`admin_credit` (free time from a dashboard command), `admin_end`, `expire`.
Money = pulses of `credit` + `held` (one pulse = one peso); `assign` moves money
already counted as `held`.

Response `200`:

```json
{ "ok": true, "server_time": 1791095201,
  "ack": { "boot_id": "0a1b2c3d", "acked_seqs": [9], "rejected_seqs": [], "inserted": 1 },
  "config": { "version": 2, "seconds_per_pulse": 240, "sync_interval_s": 15 } }
```

* `(device, boot_id, seq)` is the idempotency key; retries return `"inserted": 0`.
* The controller deletes acknowledged **and** rejected events from its buffer.
* New `config.version` → the rate applies to **future coins only**.
* Within one boot, a status with lower `uptime_ms` than the stored one is ignored.
* This response never contains time; time only reaches the box as a poll command.

### `POST /api/v1/phone/heartbeat` (tablet → cloud, every 30 s)

```json
{
  "boot_id": "5e6f7a8b", "uptime_ms": 912345, "app_version": "1.0.0",
  "mode": "production", "device_owner": true, "lock_task": "locked", "access": "granted",
  "controller": { "paired": true, "station": 2, "link": "connected", "last_ok_age_s": 0, "remaining_s": 1180 },
  "allowed_packages": ["com.google.android.youtube"],
  "config_version_applied": 2, "model": "TECNO KL5", "android_sdk": 34
}
```

A tablet enrolled without a number adopts `controller.station`. Response:

```json
{ "ok": true, "server_time": 1791095230,
  "config": { "version": 2, "allowed_packages": ["com.google.android.youtube"], "local_loss_timeout_s": 30, "seconds_per_pulse": 240 } }
```

### Dashboard (browser session, not for devices)

| Route | Notes |
|---|---|
| `GET/POST /setup` | first admin + migrations; needs `SETUP_TOKEN`; 404 once an admin exists |
| `GET/POST /login`, `POST /logout` | username sign-in; 5/min per username+IP, 20/min per IP |
| `GET /sites`, `POST /sites` | sites owned by the signed-in admin; create a site |
| `GET /sites/{site}` | live panel (Livewire, refreshes every 2 s): select tablet, +5/+15/+30 min, end session, give held coins; enrollment, configuration, devices, recent coins |
| `POST /sites/{site}/config`, `POST /sites/{site}/enroll` | new config version; one-time enrollment code |
| `POST /devices/{device}/revoke` | revoke a credential |
| `GET /audit`, `GET /account`, `POST /account/password` | audit log; password change |

Every POST needs the CSRF token. Another admin's site returns `403`.

---

## 2. Local controller API (ESP8266, plain HTTP on the LAN)

Protocol **2**. Inputs are form/query parameters; outputs are JSON. Time is
added only by coins and by dashboard commands (see `/controller/poll`).

### `GET /api/v1/info` — public, read-only

```json
{ "ok": true, "protocol": 2, "device_id": "vk-1a2b3c", "fw_version": "2.0.0",
  "stations": 4, "paired": [true, true, false, false], "pairing_open": false }
```

### `POST /api/v1/pair` — physical pairing

Only while the pairing window is open (hold FLASH 3 s or serial `pair`; the LCD
shows a 6-digit code for 120 s). Max 5 attempts per window.

Request: `code=482915&phone_id=<uuid>&station=2`

```json
{ "ok": true, "device_id": "vk-1a2b3c", "boot_id": "0a1b2c3d", "station": 2, "key": "<64 hex = 32-byte HMAC key>" }
```

Errors: `403 pairing_closed`, `403 wrong_code`, `429 too_many_attempts`,
`400 bad_station`. Pairing replaces only that tablet number's key.

### `GET /api/v1/status?station=N&nonce=<32 hex>` — signed status

```
X-VK-Signature: hex(HMAC-SHA256(key_N, "VK2|status|N|" + nonce + "|" + body))
```

```json
{
  "ok": true, "protocol": 2, "device_id": "vk-1a2b3c", "boot_id": "0a1b2c3d", "station": 2,
  "uptime_ms": 612345, "seq": 3, "session_no": 1, "session": "running", "remaining_s": 1187,
  "seconds_per_pulse": 240, "rate_version": 2, "last_added_s": 240, "last_pulses": 1,
  "selected_station": 2, "selected_ttl_s": 64, "held_pulses": 0,
  "resumed": false, "cloud": "ok", "status_upload": "ok", "nonce": "00112233445566778899aabbccddeeff"
}
```

`selected_station` is where a coin inserted now would go: the attendant's
selection, or the only paired tablet when just one is paired, else 0.

The tablet accepts the report only if the signature, echoed nonce, protocol,
`station`, device id (from pairing) all match, and — within one `boot_id` —
`uptime_ms` increased. `403 not_paired` before pairing.

### `POST /api/v1/session/end` and `POST /api/v1/unpair` — tablet admin commands

Form fields: `station`, `boot_id`, `ctr`, `mac` where
`mac = hex(HMAC-SHA256(key_N, "VK2|cmd|<end_session|unpair>|N|<boot_id>|<ctr>"))`
and `ctr` strictly increases per tablet within a boot.

Errors: `409 stale_command`, `403 bad_mac`, `403 not_paired`, `400 bad_station`.

### Wi-Fi setup portal (setup mode only)

`GET /` and `POST /save` on `http://192.168.4.1` while the coin box runs its own
WPA2 access point `VendoCoin-xxxxxx` (password on the LCD). Fields: `ssid`,
`pass`, `name`, `enroll` (cloud enrollment code), `api` (HTTPS URL), and the
`status.php` upload settings.
