# Deploying the dashboard on Hostinger

Target: `https://vendo-kiosk.ebnleadgen.online/`

The dashboard and device API are a **Laravel 13** app in `dashboard/` (PHP 8.3+,
MySQL). It replaces the earlier plain-PHP backend, which was never deployed.

## What was verified about the hosting (2026-10-04, read-only checks)

* `vendo-kiosk.ebnleadgen.online` is served by Hostinger (`platform: hostinger`,
  `panel: hpanel`, CDN `hcdn`) with **PHP 8.4.19**. The Composer dependencies are
  pinned to that version (`config.platform.php`).
* HTTPS works with a valid Let's Encrypt certificate (TLS 1.2 and 1.3).
* The subdomain already serves **`api/status.php`** (the coin box uploads to it)
  and may serve the browser demo (`docs/WEB_KIOSK.md`). The package does not
  overwrite those files, and Laravel's `.htaccess` serves existing files first,
  so `/api/status.php` and `/api/kiosk-status.php` keep working.
* The parent domain runs a separate Laravel site — do **not** touch it.
* Not verified (needs your hPanel): SSH availability, cron.

No SSH, Node.js, queue worker or cron is required on the server: assets are
built on your PC, and devices use short outbound HTTPS requests.

## Live installation (2026-10-05)

* SSH: `ssh -p 65002 u942457715@147.93.80.65` (deploy key `~/.ssh/vendo_hostinger`).
  Use `/opt/alt/php84/usr/bin/php` (the default CLI `php` is 8.3).
* Web root of the subdomain: `~/domains/ebnleadgen.online/public_html/vendo-kiosk/`
  (inside the main site's folder; the main site is a separate Laravel app — do
  not touch it). It holds the dashboard's public files **and** the existing
  `api/` (`status.php`, `db.php`, `health.php`).
* App: `~/vendo_dashboard/` (`index.php` points there with an absolute path).
* Database: shared with `status.php` (`u942457715_vendodb`; its `device_status`
  and `device_tokens` tables sit next to the dashboard's). **Never run
  `migrate:fresh`/`db:wipe` there** — it would delete the live status data.
* Backups made before installing: `~/backups/vendo-kiosk-public-*.tar.gz`.
* Hostinger's server replaces the app's `Content-Security-Policy` header with
  `upgrade-insecure-requests`; the layouts therefore also send the policy as a
  `<meta http-equiv>` tag, which browsers enforce in addition.

Updating the live app: build the zip, upload it, extract to a temporary folder,
then copy `vendo_dashboard/` over `~/vendo_dashboard/` (keep `.env` and
`storage/`) and `public_html/` into the web root (keep `api/`); run
`php artisan migrate --force`, `config:cache`, `route:cache`, `view:cache`.

## Folder layout on the server

```
domains/vendo-kiosk.ebnleadgen.online/
├── public_html/         ← document root: index.php, .htaccess, build/, images/
│   └── api/status.php   ← existing files stay where they are
└── vendo_dashboard/     ← the Laravel app (code, vendor, storage, .env) — OUTSIDE the web root
```

`public_html/index.php` loads `../vendo_dashboard`. If your document root is
elsewhere, keep `vendo_dashboard` as its sibling or edit the `$base` line in
`index.php`. Never put `.env` in a public folder.

## Step by step

### 0. Back up / inspect first
* File manager → download `public_html` as it is now (it contains `api/`).
* If `public_html` has an `index.html` (Hostinger default page or the Flutter
  browser demo), decide where it should live: it would shadow the dashboard at
  `/`. Move the demo into a subfolder (e.g. `public_html/demo/`) or delete the
  default page.

### 1. Build the package (on your PC)
```
cd dashboard
npm ci && npm run build
php tools/package.php
```
→ `dist/vendo-dashboard-2.0.0-<timestamp>.zip` (production dependencies only; no
`.env`, database, logs or sessions).

### 2. Create the database
hPanel → Databases → **MySQL Databases** → create a database and user with a
strong generated password. Note the names (prefixed like `u123456789_vendo`).

### 3. Upload
File manager → `domains/vendo-kiosk.ebnleadgen.online/` → upload the zip →
**Extract**. Merge the zip's `public_html/` into the existing one (keep `api/`)
and check that `vendo_dashboard/` sits next to `public_html/`.

Make `vendo_dashboard/storage` and `vendo_dashboard/bootstrap/cache` writable
(755 folders are normally fine on Hostinger).

### 4. Configure `.env`
In `vendo_dashboard/`, copy `.env.example` to `.env` and set:
```
APP_ENV=production
APP_DEBUG=false
APP_URL=https://vendo-kiosk.ebnleadgen.online
APP_KEY=base64:<32 random bytes, base64>
DB_CONNECTION=mysql
DB_HOST=localhost
DB_DATABASE=u123456789_vendo
DB_USERNAME=u123456789_vendo
DB_PASSWORD=<the generated password>
SESSION_DRIVER=file
SESSION_SECURE_COOKIE=true
SETUP_TOKEN=<24+ random characters>
```
Generate values on your PC:
`php -r "echo 'base64:'.base64_encode(random_bytes(32)), PHP_EOL, bin2hex(random_bytes(16)), PHP_EOL;"`
(first line → `APP_KEY`, second → `SETUP_TOKEN`). Set `.env` permissions to **600**.

### 5. HTTPS
hPanel → Security → **SSL**: active certificate (it is today) and *Force HTTPS*.
The app sends HSTS on HTTPS requests and trusts the Hostinger proxy headers.

### 6. Create the tables and the first administrator
Open `https://vendo-kiosk.ebnleadgen.online/setup`, enter the `SETUP_TOKEN`, your
name, a username and a password (10+ characters, letters and numbers). This runs
the migrations and signs you in. Then **remove `SETUP_TOKEN` from `.env`** — the
page answers 404 once an administrator exists or the token is unset.

With SSH instead: `php artisan migrate --force` in `vendo_dashboard/`, then use
`/setup` (or `php artisan tinker` to create the user).

### 7. Verify (all must pass before calling it live)
1. `GET /api/v1/health` → 200, `"database":"ok"`, `"pending_migrations":0`.
2. `/` redirects to `/login`; sign-in works; a wrong password is rejected;
   *Audit log* shows both.
3. `curl -X POST https://vendo-kiosk.ebnleadgen.online/api/v1/controller/sync`
   without a token → `401`.
4. `/api/status.php` still answers as before.
5. Add a site → **Enroll a device → Coin box** → enter the code in the coin box
   setup portal (hold FLASH 10 s) → within ~15 s the coin box shows **ONLINE**.
6. For each tablet: **Enroll a device → Tablet N** → tablet Admin → Cloud → enter
   the code; then pair it with the coin box as Tablet N (Admin → Coin box).
7. Click **Select for next coins** on a tablet card → the coin box LCD shows
   `Insert: Tab N` within ~2 s → insert a coin → only that tablet unlocks and the
   coin appears once under *Recent coins*.
8. Insert a coin with nothing selected → *Held coins* shows it → **Give to
   Tablet N** → that tablet gets the time.

## Updating (and rollback)
1. Back up: phpMyAdmin → Export; File manager → download `vendo_dashboard/.env`.
2. Build a new zip (step 1) and extract it over the existing folders — `.env`,
   `storage/` contents and the database are kept.
3. If `/api/v1/health` lists pending migrations, run `php artisan migrate --force`
   over SSH (or ask for a migration page; `/setup` only works on an empty install).

Rollback: re-extract the previous zip; restore the database export if a
migration ran (migrations are forward-only).

## Credential rotation

| Secret | How to rotate |
|---|---|
| Database password | hPanel → MySQL → change password → `DB_PASSWORD` in `.env` |
| `APP_KEY` | Only if leaked: set a new one (signs everyone out) |
| Admin password | Dashboard → your username → Change password (signs out other browsers) |
| Device token (tablet / coin box) | Site page → Devices → **Revoke** → new code → re-enroll |
| Setup token | Remove after setup |
| Tablet ↔ coin box key | Re-pair that tablet number (hold FLASH 3 s) |

## Security notes for the server
* `vendo_dashboard/` is outside the web root; nothing in `public_html` contains secrets.
* Every response sends `Cache-Control: no-store`, a strict Content-Security-Policy
  (scripts only from this site with a per-request nonce), `X-Frame-Options: DENY`
  and `nosniff`; the Hostinger CDN never caches dashboard pages or API answers.
* Login is throttled per username+IP and per IP; device enrollment per IP.
