# VeNdO Kiosk — Jo-hustle Smart Android

![VeNdO logo](assets/images/vendo_logo.png)

A coin-operated Android kiosk. **One ESP8266 coin box serves up to four
tablets**: customers insert pesos (₱1 = 4 minutes) and use administrator-approved
apps on tablets running in Android **lock task (kiosk) mode**. A Laravel
dashboard on Hostinger shows every tablet live; the attendant chooses which
tablet the next coins go to, can add or end time, and sees coins, sessions and
device status.

> **Status:** tested on the computer, the Android 14/15 emulators and the real
> coin box (see *Checks*). The dashboard is **not deployed** yet, and the
> physical tablet checklist (`docs/PHYSICAL_TEST_CHECKLIST.md`) must pass
> before calling kiosk enforcement production-ready.

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
| `dashboard/` | Laravel 13 dashboard + device API (`/api/v1`): sites, tablets, live control (Livewire), enrollment, config, audit |
| `dashboard/tests/` | Pest test suite (device API, poll channel, dashboard) |
| `dashboard/tools/package.php` | Builds the Hostinger upload zip |
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

### 2. Build the coin box
Wire it as in `docs/ESP8266_FIRMWARE.md`, flash the firmware, connect it to
Wi-Fi through its setup access point, and pair each tablet with its own
tablet number (hold FLASH 3 s for the pairing code; tablet: Admin → Coin box).

### 3. Production kiosk
Provision the phone as Device Owner (`docs/DEVICE_OWNER_PROVISIONING.md`),
then Admin → Kiosk mode → *Enable production kiosk*.

### 4. Dashboard
Deploy `dashboard/` to Hostinger (`docs/DEPLOYMENT_HOSTINGER.md`), add a site,
and enroll the coin box and each tablet (Tablet 1–4) with one-time codes. Then
the site page lets the attendant pick the tablet for the next coins.

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
cd dashboard && php artisan test                # dashboard + device API tests (SQLite in-memory)
cd dashboard && npm run build && php tools/package.php   # → dist/vendo-dashboard-*.zip for Hostinger
arduino-cli compile --fqbn esp8266:esp8266:nodemcuv2 firmware/vendo_coin_controller
```

Local dashboard (SQLite): in `dashboard/`, `composer install`, `npm install`,
`cp .env.example .env`, `php artisan key:generate`, set `SESSION_SECURE_COOKIE=false`,
then `php artisan migrate:fresh --seed --seeder=DemoSeeder` and `php artisan serve`
(sign in as `demo` / `demo-pass-123`). Never commit `.env`.

## Checks run on 2026-10-05

| Check | Result |
|---|---|
| `flutter analyze` | no issues |
| `flutter test` | 105 passed |
| Kotlin unit tests (`testDebugUnitTest`) | 44 passed |
| `flutter build apk --release` | built and signed (minSdk 29, targetSdk 36) |
| Dashboard `php artisan test` (Pest) | 37 passed |
| `web_backend/tests/run.php` (kiosk-status endpoint) | 34 checks passed |
| Dashboard in headless Chrome (desktop + phone width, strict CSP) | no console errors; Livewire actions work |
| Packaged dashboard zip, production mode (SQLite) | health 200, login/setup 200, unknown API 404 |
| Firmware 2.0 compile (NodeMCU 1.0) | OK, RAM 47 %, flash 43 % |
| Real coin box + Pixel Tablet emulator | 1.x pairing migrated to Tablet 1, protocol 2 link verified, single-tablet auto-routing |

## Application ID

`online.ebnleadgen.vendokiosk` (changed from the template's `com.example.vendo_kiosk`).
Release builds are signed with the key referenced by `android/key.properties`
(gitignored; the keystore lives outside the repo). The release build fails if
that file is missing. Back up the keystore and its password: a Device Owner app
cannot switch signing keys without re-provisioning (factory reset).
