# Vendo Kiosk API reference

There are two APIs:

1. **Cloud API** (`https://vendo-kiosk.ebnleadgen.online/api/v1/…`) on Hostinger.
   Devices call it **outbound** over HTTPS. It records events and status and
   hands out configuration. **It never grants paid time.**
2. **Local controller API** (`http://<esp8266-ip>/api/v1/…`) on the ESP8266,
   used only by the paired phone on the same Wi-Fi. The ESP8266 is the
   authority for paid time.

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
revocable per device from the dashboard. A controller credential cannot call
phone endpoints and vice-versa (`401`).

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
| 429 | `rate_limited` | too many requests |
| 503 | — | health: DB down or migrations pending |

### `GET /api/v1/health`

No authentication. Used by monitoring and deployment verification.

```json
{
  "ok": true,
  "service": "vendo-kiosk",
  "api_version": "v1",
  "backend_version": "1.0.0",
  "database": "ok",
  "pending_migrations": 0,
  "server_time": 1791095200
}
```

`503` with `"ok": false` when the database is unreachable or migrations are pending.

### `POST /api/v1/devices/enroll`

Redeems a **one-time** enrollment code generated in the dashboard
(Kiosk → *Generate phone code* / *Generate coin controller code*). Codes are
single-use, typed (phone vs controller) and expire after 30 minutes.
Rate limit: 10 attempts per IP per hour.

Request:

```json
{ "device_type": "controller", "enrollment_code": "89KW4-8Y2MW", "name": "Front coin box", "hardware_id": "vk-1a2b3c" }
```

Response `201` (the token is shown **once**; store it securely):

```json
{
  "ok": true,
  "device_id": "107d8de56f6a8918",
  "device_token": "vkd_107d8de56f6a8918_xbK…",
  "api_base": "https://vendo-kiosk.ebnleadgen.online/api/v1"
}
```

### `POST /api/v1/controller/sync` (ESP8266 → cloud)

Sent every `sync_interval_s` (default 15 s) and ~3 s after a coin.

```json
{
  "protocol": 1,
  "boot_id": "0a1b2c3d",
  "uptime_ms": 60000,
  "fw_version": "1.0.0",
  "config_version_applied": 1,
  "status": {
    "session": "running",
    "remaining_s": 420,
    "seq": 1,
    "session_no": 1,
    "seconds_per_pulse": 240,
    "rate_version": 1,
    "wifi_rssi": -61,
    "free_heap": 21800,
    "buffered_events": 1,
    "dropped_events": 0,
    "phone_last_poll_age_s": 1
  },
  "events": [
    { "seq": 1, "type": "credit", "session_no": 1, "pulses": 2, "seconds": 480,
      "rate_version": 1, "remaining_after": 480, "uptime_ms": 0, "unix_time": 1791095140 }
  ]
}
```

* `boot_id` — random per controller boot. `(device, boot_id, seq)` is the
  **idempotency key**: retried uploads are acknowledged but not stored twice.
* `type` — `credit` (coin accepted) or `expire` (session reached zero).
* At most 32 events per request.

Response `200`:

```json
{
  "ok": true,
  "server_time": 1791095201,
  "ack": { "boot_id": "0a1b2c3d", "acked_seqs": [1], "rejected_seqs": [], "inserted": 1 },
  "config": { "version": 2, "seconds_per_pulse": 240, "sync_interval_s": 15 }
}
```

* The controller deletes `acked_seqs` **and** `rejected_seqs` (invalid events)
  from its buffer. A retry of the same batch returns `"inserted": 0`.
* `config.version` higher than the controller's applied version → the
  controller adopts the new rate **for future coins only** and reports
  `config_version_applied` on the next sync.
* Status ordering: within one boot, a report with a lower `uptime_ms` than the
  stored one is ignored (stale/delayed). A new `boot_id` always replaces it.
* The response contains **no remaining time** — the cloud never sets device time.

### `POST /api/v1/phone/heartbeat` (phone → cloud)

Every 30 s from the native foreground service.

```json
{
  "boot_id": "5e6f7a8b",
  "uptime_ms": 912345,
  "app_version": "1.0.0",
  "mode": "production",
  "device_owner": true,
  "lock_task": "locked",
  "access": "granted",
  "controller": { "paired": true, "link": "connected", "last_ok_age_s": 0, "remaining_s": 1180 },
  "allowed_packages": ["com.google.android.youtube"],
  "config_version_applied": 2,
  "model": "TECNO KL5",
  "android_sdk": 34
}
```

`access` is `granted` or the deny reason (`no_time`, `controller_lost`,
`controller_not_paired`, `not_device_owner`, `unconfigured`).

Response `200`:

```json
{
  "ok": true,
  "server_time": 1791095230,
  "config": {
    "version": 2,
    "allowed_packages": ["com.google.android.youtube", "com.android.chrome"],
    "local_loss_timeout_s": 30,
    "seconds_per_pulse": 240
  }
}
```

When `config.version` is newer than the phone's applied version the phone
replaces its allowed-app list and loss timeout, then reports the new
`config_version_applied`.

### Dashboard (cookie session, not for devices)

| Route | Notes |
|---|---|
| `GET /setup`, `POST /setup` | first admin + migrations; needs `SETUP_TOKEN`, disabled once an admin exists |
| `GET/POST /login`, `POST /logout` | Argon2id/bcrypt passwords, rate limited (8/user, 20/IP per 15 min) |
| `GET /` | kiosks owned by the signed-in admin |
| `POST /kiosks` | create kiosk |
| `GET /kiosks/{id}` | devices, config, events, sessions |
| `GET /kiosks/{id}/status.json` | auto-refresh data (owner only) |
| `POST /kiosks/{id}/config` | new config version (audited) |
| `POST /kiosks/{id}/enroll-code` | one-time code (audited) |
| `POST /devices/{id}/revoke` | revoke credential (audited) |
| `GET /audit`, `GET/POST /account`, `GET/POST /diagnostics` | audit log, password change, migrations |

Every POST requires the CSRF token. Another admin's kiosk returns `404`.

---

## 2. Local controller API (ESP8266, plain HTTP on the LAN)

Protocol version **1**. Inputs are form/query parameters; outputs are JSON.
**No endpoint adds time.** Only accepted coin pulses do.

### `GET /api/v1/info` — public, read-only

```json
{ "ok": true, "protocol": 1, "device_id": "vk-1a2b3c", "fw_version": "1.0.0", "paired": true, "pairing_open": false }
```

### `POST /api/v1/pair` — physical pairing

Only while the pairing window is open (hold the FLASH button 3 s; the LCD shows
a 6-digit code for 120 s). Max 5 attempts per window.

Request (`application/x-www-form-urlencoded`): `code=482915&phone_id=<uuid>`

Response `200`:

```json
{ "ok": true, "device_id": "vk-1a2b3c", "boot_id": "0a1b2c3d", "key": "<64 hex chars = 32-byte HMAC key>" }
```

Errors: `403 pairing_closed`, `403 wrong_code`, `429 too_many_attempts`.
Pairing a new phone replaces the previous key (old phone becomes unpaired).

### `GET /api/v1/status?nonce=<32 hex>` — signed status

The phone sends a fresh random nonce every request. Response:

```
HTTP/1.1 200 OK
X-VK-Signature: 3f9c…(64 hex)
Content-Type: application/json
```

```json
{
  "ok": true, "protocol": 1, "device_id": "vk-1a2b3c", "boot_id": "0a1b2c3d",
  "uptime_ms": 612345, "seq": 3, "session_no": 1, "session": "running",
  "remaining_s": 1187, "seconds_per_pulse": 240, "rate_version": 2,
  "last_added_s": 240, "last_pulses": 1, "resumed": false, "cloud": "ok",
  "nonce": "00112233445566778899aabbccddeeff"
}
```

`X-VK-Signature = hex(HMAC-SHA256(key, "VK1|status|" + nonce + "|" + body))`

The phone accepts the report only if the signature, echoed nonce, protocol,
device id (from pairing) all match, and — within one `boot_id` — `uptime_ms`
is higher than the last accepted report. `403 not_paired` before pairing.

### `POST /api/v1/session/end` and `POST /api/v1/unpair` — admin commands

Form fields: `boot_id`, `ctr`, `mac` where
`mac = hex(HMAC-SHA256(key, "VK1|cmd|<end_session|unpair>|<boot_id>|<ctr>"))`
and `ctr` is strictly increasing (replay protection; the controller's counter
resets on reboot, which also changes `boot_id`).

Errors: `409 stale_command`, `403 bad_mac`, `403 not_paired`.

### Wi-Fi setup portal (setup mode only)

`GET /` and `POST /save` on `http://192.168.4.1` while the controller runs its
own WPA2 access point `VendoCoin-xxxxxx` (password shown on the LCD).
Fields: `ssid`, `pass`, `name`, `enroll` (cloud enrollment code), `api` (HTTPS URL).
