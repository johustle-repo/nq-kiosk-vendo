# VeNdO Kiosk — Jo-hustle Smart Android

![VeNdO logo](assets/images/vendo_logo.png)

A coin-operated Android kiosk. Customers insert coins into an ESP8266-based
coin box, get time (1 pulse = 4 minutes), and use administrator-approved apps
on a TECNO Spark 30C running in Android **lock task (kiosk) mode**. A PHP/MySQL
dashboard on Hostinger records coins, sessions and device status.

> **Status:** code complete and tested on the computer (see *Checks*). It has
> **not** yet been tested on the physical phone/coin hardware and the backend is
> **not deployed** yet. Do not treat kiosk enforcement as production-ready until
> `docs/PHYSICAL_TEST_CHECKLIST.md` passes.

## Project owner and author

**Jonathan Quiles** — project owner and author
Contact: [jonathanquiles59@gmail.com](mailto:jonathanquiles59@gmail.com)

## What's in this repository

| Path | What |
|---|---|
| `lib/` | Flutter UI (payment screen, paid launcher, setup, admin settings) |
| `android/app/src/main/kotlin/online/ebnleadgen/vendokiosk/` | Kotlin: Device Policy Controller, lock task enforcement, foreground service, controller protocol, secure storage |
| `android/app/src/test/` | Kotlin unit tests (session timing, access policy, protocol, PIN) |
| `test/` | Flutter unit + widget tests |
| `firmware/vendo_coin_controller/` | ESP8266 Arduino firmware (coin pulses, LCD, local API, cloud sync) |
| `backend/` | PHP backend + admin dashboard (`public/` = web root, `app/` = private code, migrations, `.env.example`) |
| `backend/tests/run.php` | Backend test suite |
| `web_backend/` | `GET /api/kiosk-status.php` for the browser demo (fits the existing live `api/` folder), token tool, simulator, tests |
| `lib/src/web/` | Flutter web client (polling, countdown, token storage) |
| `docs/` | Guides (below) |
| `dist/` | Built deliverables: debug and signed release APK, firmware binaries, backend upload zip (not committed) |

## Guides

* [Architecture and defined behaviours](docs/ARCHITECTURE.md) — who is authoritative, what happens on coin/expiry/network loss/restarts
* [API reference with JSON examples](docs/API.md) — cloud API and local controller API
* [ESP8266 hardware & firmware](docs/ESP8266_FIRMWARE.md) — wiring, power, **3.3 V level shifting**, flashing, persistence
* [Device Owner provisioning](docs/DEVICE_OWNER_PROVISIONING.md) — ⚠ requires a factory reset (data loss)
* [Hostinger deployment](docs/DEPLOYMENT_HOSTINGER.md) — document root, HTTPS, DB, migrations, backups, rollback, credential rotation
* [Security model and limitations](docs/SECURITY.md)
* [Troubleshooting and recovery](docs/RECOVERY.md)
* [Physical device test checklist](docs/PHYSICAL_TEST_CHECKLIST.md)
* [Browser kiosk demo + `/api/kiosk-status.php`](docs/WEB_KIOSK.md) — Flutter web, token auth, CORS, Hostinger deployment

## Quick start

### 1. Try it on any Android phone (demo mode)
1. Install `dist/vendo-kiosk-1.0.0-debug.apk` (Android 10+).
2. Create an administrator PIN (there is no default PIN) and **write down the
   recovery code**.
3. Choose **Demo mode**. Use the clearly labelled *SIMULATED* coin buttons,
   pick apps in Admin (tap the timer 7 times quickly → PIN) → Apps, and launch them.
4. Demo mode does **not** restrict other apps — it says so on every screen.

> The **web** build is a browser demo that reads the live timer from
> `/api/kiosk-status.php` (see docs/WEB_KIOSK.md); it cannot enforce anything.
> Desktop builds run an in-memory preview. The kiosk itself is the Android APK.

### 2. Build the coin controller
Wire it as in `docs/ESP8266_FIRMWARE.md`, flash the firmware, connect it to
Wi-Fi through its setup access point, and pair the phone (hold FLASH 3 s for
the pairing code).

### 3. Production kiosk
Provision the phone as Device Owner (`docs/DEVICE_OWNER_PROVISIONING.md`),
then Admin → Kiosk mode → *Enable production kiosk*.

### 4. Dashboard
Deploy `backend/` to Hostinger (`docs/DEPLOYMENT_HOSTINGER.md`), create a kiosk,
and enroll the phone and controller with the one-time codes.

## Rates

| Peso | Time |
|---|---|
| ₱1 | 4 min |
| ₱5 | 20 min |
| ₱10 | 40 min |
| ₱20 | 80 min |

The coin acceptor sends one pulse per peso; each peso adds 240 s (configurable per kiosk in the dashboard; changes apply
to future coins only). More coins extend the running session.

## Developer commands

```
flutter pub get
flutter analyze
flutter test
flutter build apk --debug                       # → build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release                     # signed with android/key.properties → app-release.apk
cd android && ./gradlew :app:testDebugUnitTest  # Kotlin unit tests
php backend/tests/run.php                       # backend tests (SQLite in-memory)
php backend/tools/package.php                   # → dist/vendo-backend-*.zip for Hostinger
arduino-cli compile --fqbn esp8266:esp8266:nodemcuv2 firmware/vendo_coin_controller
```

Local backend for development (SQLite): create `backend/app/.env` with
`DB_DRIVER=sqlite`, `DB_PATH=<some path>/dev.sqlite`, `SETUP_TOKEN=<24+ chars>`,
`SESSION_SECURE=0`, then `php -S 127.0.0.1:8000 -t backend/public backend/public/index.php`.
Never commit `.env`.

## Checks run on 2026-10-04

| Check | Result |
|---|---|
| `flutter analyze` | no issues |
| `flutter test` | 47 passed |
| Kotlin unit tests (`testDebugUnitTest`) | 40 passed |
| `flutter build apk --debug` | built (minSdk 29, targetSdk 36) |
| Android lint | 0 errors in project code (2 errors only in the machine-generated `android/local.properties`) |
| Backend `php -l` + `backend/tests/run.php` | 95 checks passed |
| `web_backend/tests/run.php` (kiosk-status endpoint) | 29 checks passed |
| Browser end-to-end (headless Chrome → localhost:5173 → PHP API with CORS) | preflight 204, polling every ~3 s, 200s |
| Backend HTTP smoke test (local PHP server, SQLite) | setup → login → kiosk → enroll → sync → dedup → 401 without token: OK |
| Firmware compile (NodeMCU 1.0 and D1 mini, ESP8266 core 3.1.2) | OK, RAM 44 %, flash 41 % |

## Application ID

`online.ebnleadgen.vendokiosk` (changed from the template's `com.example.vendo_kiosk`).
Release builds are signed with the key referenced by `android/key.properties`
(gitignored; the keystore lives outside the repo). The release build fails if
that file is missing. Back up the keystore and its password: a Device Owner app
cannot switch signing keys without re-provisioning (factory reset).
