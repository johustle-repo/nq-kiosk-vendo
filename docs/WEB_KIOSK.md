# Browser kiosk demo (Flutter web) + `GET /api/kiosk-status.php`

The Flutter **web** build shows the payment screen and a live HH:MM:SS countdown
read from the server. It is a **demo/display only**:

> **Browser demo: Android kiosk enforcement unavailable** (shown on every screen)

No platform channels are used on the web; app tiles are labelled
*PREVIEW — not launchable*. Real kiosk enforcement is the Android APK.

## What is on the live server today (inspected 2026-10-04, read-only)

| URL | Result | Meaning |
|---|---|---|
| `/` | Hostinger "Default page" | no web app deployed yet |
| `/api/` | 403 | an `api/` folder **exists** (listing denied) |
| `/api/health.php` | `{"status":"ok","service":"vendo-kiosk"}` | existing |
| `/api/status.php` | 405, `Allow: POST` | existing — most likely the ESP8266 upload |
| `/api/db.php` | 200, empty body | existing DB include |
| `/api/.htaccess` | 403 | existing |
| `/api/kiosk-status.php` | 404 | to be added |

These existing files are **not** part of this repository and were not read
(PHP source is not visible over HTTP). Nothing in this package overwrites them.

## Files

| In the package (`dist/vendo-web-*.zip`) | Goes to |
|---|---|
| `public_html/index.html`, `main.dart.js`, `flutter*.js`, `assets/`, `canvaskit/`, `icons/`, … | the site's document root |
| `public_html/api/kiosk-status.php` | `public_html/api/` (new file) |
| `public_html/api/.htaccess.snippet` | lines to **add** to the existing `api/.htaccess` |
| `public_html/.htaccess.root-example` | rules to **merge** into the root `.htaccess` |
| `vendo_web/` (lib, config template, migration) | **outside** the web root, next to `public_html` |

Source: `web_backend/` and `lib/src/web/`.

## The endpoint

`GET /api/kiosk-status.php?device=vendo-001` (optional long-poll: `&wait=20&since_boot=<boot_id>&since_seq=<n>&since_reported=<unix>`)

Headers: `Authorization: Bearer vkw_<16 hex>_<43 chars>` (or `X-Kiosk-Token: …`
if the host strips `Authorization`).

```json
{
  "ok": true,
  "device": "vendo-001",
  "status_available": true,
  "remaining_seconds": 1200,
  "boot_id": "dee6c728",
  "sequence_number": 1,
  "last_pulses": 5,
  "age_seconds": 4,
  "reported_at": "2026-10-04T07:35:39Z",
  "stale": false,
  "stale_after_seconds": 60,
  "server_time": 1791099343
}
```

* `age_seconds` is computed by the **database clock** from the status row's
  update time, so it matches how the upload endpoint wrote it (e.g. `NOW()`).
* If several rows exist for the device, the newest is used.
* No status yet → `"status_available": false` and nulls.

| Status | `error` | When |
|---|---|---|
| 401 | `unauthorized` | missing / malformed / unknown / revoked / expired token — including the ESP8266 upload token, which is never accepted |
| 403 | `forbidden_device` | `device` is not the device this token is bound to |
| 403 | `origin_not_allowed` | CORS preflight from an origin not in the allow-list |
| 405 | `method_not_allowed` | anything except GET/OPTIONS |
| 429 | `rate_limited` | more than `rate_limit_per_minute` (default 60) for this token |
| 500 | `status_source_misconfigured` | configured table/columns not found (details only in the PHP error log) |
| 503 | `unavailable` | `config.php` missing or database unreachable |

The endpoint is read-only. It never changes `device_status` and cannot add time.

## Authentication model

* **Separate credential.** Browser tokens live in a new table
  `web_kiosk_tokens` (migration `vendo_web/migrations/001_web_kiosk_tokens.sql`).
  They are unrelated to the ESP8266 upload credential, which this endpoint
  neither reads nor accepts.
* **Device ownership.** Each token is bound to exactly one `device_code`
  (`vendo-001`). The server only ever queries that device; asking for another
  returns 403 without data.
* Only `SHA-256(secret)` is stored. Tokens can expire and be revoked.
* In the browser the token is kept in `sessionStorage` (forgotten when the tab
  closes) or, if "Remember on this browser" is ticked, `localStorage`. Use that
  only on a trusted device; anyone with access to the browser profile can read it.

### Create a token (on your PC; no SSH needed)

```
php web_backend/tools/make-web-token.php vendo-001 "Front browser" 90
```

It prints the token **once** and an `INSERT INTO web_kiosk_tokens …` statement
that contains only the hash. Run that statement in phpMyAdmin. Revoke with:

```sql
UPDATE web_kiosk_tokens SET revoked_at = UTC_TIMESTAMP() WHERE public_id = '<id printed by the tool>';
```

## Local browser development

Nothing touches production. The simulator plays the ESP8266.

```powershell
# 1. Dev database + config + token (writes web_backend/vendo_web/config.php and dev.sqlite, both git-ignored)
php web_backend/tools/dev-sim.php init          # copy the vkw_… token it prints

# 2. Local API (serves web_backend/public_html, i.e. /api/kiosk-status.php)
php -S 127.0.0.1:8000 -t web_backend/public_html

# 3. Flutter web on the ONE allowed development origin http://localhost:5173
flutter run -d chrome --web-port 5173 --dart-define=VENDO_API_BASE=http://127.0.0.1:8000
#    In Android Studio: choose the run configuration "Web demo (local API)" with device "Chrome (web)".
#    (The default "main.dart" configuration picks a random port, which the local API's CORS rejects.)
#    In VS Code: launch "Web demo (local API)".

# 4. In another terminal: insert coins / keep uploading
php web_backend/tools/dev-sim.php coin 1        # +4 min
php web_backend/tools/dev-sim.php coin 5        # +20 min
php web_backend/tools/dev-sim.php run           # upload every 10 s; Ctrl+C → "STALE" after 60 s
```

Paste the token into the app. Stop step 2 to see "connection failed".

CORS is enabled only for origins listed in `cors_allowed_origins` (the dev
config lists exactly `http://localhost:5173`). The endpoint echoes that exact
origin, answers the `OPTIONS` preflight with 204, allows only `GET` and the
`Authorization` / `X-Kiosk-Token` headers, sends `Vary: Origin`, and never uses
`*` or credentials/cookies. No browser security flags or proxies are needed.

**Against the production API from localhost (optional):** add
`'http://localhost:5173'` to `cors_allowed_origins` in the **server's**
`vendo_web/config.php`, run
`flutter run -d chrome --web-port 5173 --dart-define=VENDO_API_BASE=https://vendo-kiosk.ebnleadgen.online`,
and remove the origin again when finished.

## Production deployment (Hostinger)

Production uses **same-origin** requests (`/api/kiosk-status.php`), so no CORS
entry is needed.

### 0. Inspect and back up first (do not skip)
1. hPanel → File manager → `domains/vendo-kiosk.ebnleadgen.online/` (confirm the
   subdomain's real document root in hPanel → Domains → Subdomains).
2. Download a copy of `public_html/` **including `api/` and any `.htaccess`**.
3. Note what is in `public_html/` besides `api/` (probably Hostinger's
   `default.php` or `index.html`). Open the existing root `.htaccess` and
   `api/.htaccess` and keep their contents.
4. phpMyAdmin → select the database used by `api/db.php` → Export (backup).
5. Run `SHOW COLUMNS FROM device_status;` and compare with the mapping in
   `config.example.php` (`device_id`, `remaining_seconds`, `boot_id`,
   `sequence_number`, `last_pulses`, `updated_at`). Adjust the mapping if names
   differ, and set `updated_type` to `unix` if `updated_at` is an integer.

### 1. Build and package (on your PC)
```
flutter build web --release
php web_backend/tools/package-web.php
```
(`package-web.php` refuses a build that contains a development API URL.)

### 2. Database
phpMyAdmin → SQL → paste `vendo_web/migrations/001_web_kiosk_tokens.sql`.
It only **creates** `web_kiosk_tokens`; nothing existing is changed.
Then create a token (see above) and run its INSERT.

### 3. Private folder
Upload `vendo_web/` next to `public_html/` (not inside it). Copy
`config.example.php` to `config.php`, fill in the same DB credentials that
`api/db.php` uses (from hPanel → Databases), keep `cors_allowed_origins => []`,
set permissions to 600.

### 4. Web root
Upload the package's `public_html/` contents **into** the existing
`public_html/`:
* add/replace the Flutter files (`index.html`, `main.dart.js`, `flutter*.js`,
  `manifest.json`, `version.json`, `favicon.png`, `assets/`, `canvaskit/`, `icons/`);
* add `api/kiosk-status.php` — **do not delete or overwrite** `api/status.php`,
  `api/db.php`, `api/health.php` or `api/.htaccess`;
* remove Hostinger's `default.php`/placeholder `index.html` **only after**
  confirming in step 0 it is just the default page (the new `index.html` replaces it).

### 5. `.htaccess`
* Root: merge `.htaccess.root-example` into `public_html/.htaccess` (keep any
  existing PHP handler lines). Key rules: `RewriteRule ^api(/|$) - [L]` stops all
  API paths before the SPA fallback; real files are served as-is; everything
  else goes to `index.html`.
* `api/.htaccess`: append the lines from `api/.htaccess.snippet` (Authorization
  pass-through) if that file uses `RewriteEngine On`.
* Delete the two `*.example`/`*.snippet` helper files from the server afterwards.

### 6. Verify (all must pass)
```
curl -s https://vendo-kiosk.ebnleadgen.online/api/health.php            # existing API still works
curl -s -i https://vendo-kiosk.ebnleadgen.online/api/kiosk-status.php   # 401 JSON (not index.html!)
curl -s -H "Authorization: Bearer vkw_…" "https://vendo-kiosk.ebnleadgen.online/api/kiosk-status.php?device=vendo-001"
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" https://vendo-kiosk.ebnleadgen.online/api/no-such-file.php   # 404, not text/html of the app
curl -s https://vendo-kiosk.ebnleadgen.online/some/client/route | grep -o "<title>[^<]*"                                  # app shell
```
Then open `https://vendo-kiosk.ebnleadgen.online/`, enter the token, insert a
coin on the real controller and confirm the countdown updates. If
`status.php` writes device status only every N seconds, the browser updates at
that pace (polling is every 3 s).

### Rollback
Restore the downloaded `public_html` copy (and drop `web_kiosk_tokens` if you
want to remove it entirely: `DROP TABLE web_kiosk_tokens;`).

## Browser behaviour (implemented in `lib/src/web/`)

* **Fast coin response (long-polling).** Each request tells the server what the
  browser already has (`wait=20&since_boot=…&since_seq=…&since_reported=…`).
  The server re-reads `device_status` every 300 ms and answers the moment a
  newer upload exists, otherwise after 20 s. Measured locally: coin written to
  the database → browser answer in ≈0.25 s. Only one request is ever in
  flight; new data triggers the next request immediately, unchanged answers
  keep at least 3 s between requests, failures retry after 3 s. Servers or
  configs without long-poll (`long_poll_max_seconds = 0`) fall back to plain
  3-second polling automatically.
* **End-to-end coin latency = coin box upload delay + ≈0.3 s.** The browser can
  only show a coin after the ESP8266 has written it via `api/status.php`. If the
  existing firmware uploads on a fixed timer, make it upload **immediately after
  each coin** (the firmware in `firmware/` does this ~0.4 s after the pulse train ends).
* Shared hosting note: each open kiosk tab keeps one PHP worker busy while a
  request is held. One or a few tabs are fine; for many tabs lower
  `long_poll_max_seconds` or set it to 0. The Windows `php -S` dev server is
  single-threaded, so use one browser tab when testing locally.
* Countdown = `remaining_seconds − age_seconds` at receipt, minus time elapsed
  locally on a monotonic clock; redrawn every 250 ms.
* Repeated responses about the same upload (same boot, sequence and upload time)
  keep the existing baseline — polling cannot add credit. Responses about an
  older upload are ignored; a new `boot_id` replaces the baseline; a higher
  `sequence_number` shows "Coin received".
* Separate indicators: **Server** (connected / connection failed N×) and the
  **device** (reporting N s ago / STALE / no status). On failure the last known
  time keeps counting down with a "not being updated" notice. 401/403 stop
  polling and offer token re-entry.
* `MethodChannelKioskBridge` refuses every call off Android
  (`unsupported_platform`); on the web the app never constructs it.
