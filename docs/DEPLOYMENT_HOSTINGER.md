# Deploying the backend and dashboard on Hostinger

Target: `https://vendo-kiosk.ebnleadgen.online/`

## What was verified about the hosting (2026-10-04, read-only checks)

* `vendo-kiosk.ebnleadgen.online` is served by Hostinger (`platform: hostinger`,
  `panel: hpanel`, CDN `hcdn`) with **PHP 8.4.19**; it currently shows the
  Hostinger **default page** and `/api/v1/health` returns 404 — nothing is
  deployed there yet.
* HTTPS works with a valid Let's Encrypt certificate (TLS 1.2 and 1.3).
* The parent domain runs a separate PHP (Laravel) site — do **not** touch it.
* Not verified (needs your hPanel): plan type, SSH availability, Node.js, cron.

Because of that, the backend is **plain PHP 8.1+ with MySQL and no Composer
dependencies**. It needs no SSH, Node.js, WebSockets or long-running processes;
devices use short outbound HTTPS requests (polling).

## Folder layout on the server

Hostinger subdomains usually get their own document root, for example:

```
/home/<user>/domains/vendo-kiosk.ebnleadgen.online/public_html   ← document root
```

(Check yours in hPanel → Websites → Dashboard → File manager, or
Domains → Subdomains, which shows the folder of each subdomain.)

Upload the package so that `vendo_app` is a **sibling** of `public_html`
(outside the web root):

```
domains/vendo-kiosk.ebnleadgen.online/
├── public_html/        ← from the zip's public_html/ (index.php, .htaccess, assets/)
└── vendo_app/          ← from the zip's vendo_app/ (code, migrations, .env)
```

If your subdomain's document root is a folder inside the main site
(e.g. `domains/ebnleadgen.online/public_html/vendo-kiosk`), put `vendo_app`
next to that folder and adjust the first path in `public_html/index.php`
(`$candidates`). Never place `.env` inside a public folder.

## Step by step (no SSH needed)

### 0. Back up / inspect first
* hPanel → File manager: confirm the subdomain's `public_html` only contains the
  Hostinger default `index.html`/`default.php` (that is what the site serves now).
  Download a copy of anything else before replacing it.
* If you reuse an existing database, export it first (phpMyAdmin → Export).
  The migration only **creates** new tables, but review it before running.

### 1. Build the package (on your PC)
```
php backend/tools/package.php
```
→ `dist/vendo-backend-1.0.0-<timestamp>.zip` (contains no secrets).

### 2. Create the database
hPanel → Databases → **MySQL Databases** → create database + user with a
strong generated password. Note the DB name, user (both prefixed like
`u123456789_vendo`) and host (normally `localhost`).

### 3. Upload
File manager → `domains/vendo-kiosk.ebnleadgen.online/` → upload the zip →
Extract. You should see `public_html/` and `vendo_app/` side by side. Remove the
old Hostinger default `index.html` / `default.php` from `public_html` if present
(it takes precedence over `index.php` on some setups).

### 4. Configure `.env`
In `vendo_app/`, copy `.env.example` to `.env` and fill in:
```
APP_URL=https://vendo-kiosk.ebnleadgen.online
DB_HOST=localhost
DB_NAME=u123456789_vendo
DB_USER=u123456789_vendo
DB_PASS=<the generated password>
SETUP_TOKEN=<32+ random characters>
SESSION_SECURE=1
```
Generate the token on your PC: `php -r "echo bin2hex(random_bytes(24));"`.
Set file permissions of `.env` to **600** (File manager → Permissions).

### 5. HTTPS
hPanel → Security → **SSL**: make sure the subdomain has an active certificate
(it does today) and enable *Force HTTPS*. The `.htaccess` also redirects HTTP
to HTTPS and sends HSTS.

### 6. Run migrations + create the first administrator
Open `https://vendo-kiosk.ebnleadgen.online/setup`, enter the `SETUP_TOKEN`, an
admin username and a 12+ character password. This applies
`vendo_app/migrations/001_init.sql` and creates the admin.
Then **remove `SETUP_TOKEN` from `.env`** (Diagnostics warns while it is set).

Alternative: phpMyAdmin → Import `001_init.sql`, then
`php vendo_app/bin/migrate.php` and `php vendo_app/bin/create-admin.php <name>`
over SSH (if your plan has it). Note: importing via phpMyAdmin does not record
the migration — prefer `/setup`.

### 7. Routing check
API routing is done by `public_html/.htaccess` (front controller). Verify:
```
curl https://vendo-kiosk.ebnleadgen.online/api/v1/health
```
→ `{"ok":true,...,"database":"ok","pending_migrations":0}`

### 8. Client IP behind the Hostinger CDN
Sign in → **Diagnostics**. If `REMOTE_ADDR` is a CDN address and
`X-Forwarded-For` shows your real IP, set `TRUSTED_IP_HEADER=HTTP_X_FORWARDED_FOR`
in `.env` so login/enrollment rate limits are per visitor.

### 9. Scheduled job (optional)
Not required (offline status is computed when pages load). For housekeeping,
hPanel → Advanced → **Cron Jobs**, daily:
```
/usr/bin/php /home/<user>/domains/vendo-kiosk.ebnleadgen.online/vendo_app/bin/maintenance.php
```

### 10. Verify the deployment (all must pass before calling it live)
1. `GET /api/v1/health` → 200, `database: ok`, `pending_migrations: 0`.
2. Dashboard loads at `/`, redirects to `/login`; sign-in works; wrong password
   is rejected; `/audit` shows the login.
3. Create a kiosk → generate a **coin controller** code → enroll the ESP8266
   (setup portal) → within ~15 s the device shows **ONLINE** with reported time.
4. Insert a coin → the event appears under *Coin events* once (not twice).
5. Generate a **phone** code → enroll in the app (Admin → Cloud) → the phone row
   shows mode / Device Owner / access.
6. `curl -X POST https://vendo-kiosk.ebnleadgen.online/api/v1/controller/sync`
   without a token → `401`.

## Updating (and rollback)

1. Back up: phpMyAdmin → Export the database; File manager → compress and
   download `public_html` and `vendo_app` (keep `.env`!).
2. Upload the new zip, extract **over** the existing folders (your `.env` is not
   in the zip and is kept).
3. Sign in → Diagnostics → *Apply pending migrations* if any are listed.
4. Check `/api/v1/health`.

Rollback: restore the downloaded folders. If a migration ran, restore the
database export too (migrations are forward-only).

Hostinger also keeps automatic backups (hPanel → Files → Backups) depending on
plan — check what yours includes.

## Credential rotation

| Secret | How to rotate |
|---|---|
| Database password | hPanel → MySQL → change password → update `DB_PASS` in `.env` |
| Admin password | Dashboard → Account (signs out other sessions) |
| Device token (phone/ESP8266) | Dashboard → kiosk → *Revoke* → generate a new code → re-enroll |
| Setup token | Remove after setup; set a new one only to re-run `/setup` on an empty DB |
| Phone ↔ controller key | Re-pair (hold FLASH 3 s); old key stops working immediately |

## Security notes for the server
* `vendo_app/` is outside the web root and also has `Require all denied`.
* `.htaccess` blocks dotfiles and `.env/.sql/.md/.log` downloads.
* All responses send `Cache-Control: no-store` so the Hostinger CDN never
  caches dashboard pages or API answers.
