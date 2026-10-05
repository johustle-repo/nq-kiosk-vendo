// Vendo coin controller — compile-time configuration.
// Values that operators change at run time (Wi-Fi, cloud enrollment, rates)
// are NOT here; they are set through the setup portal or the cloud dashboard.
#pragma once

#define FW_VERSION "2.0.0"
// Local phone protocol 2: one coin box, up to MAX_STATIONS tablets, per-tablet keys.
#define PROTOCOL_VERSION 2

// ---------------------------------------------------------------- tablets
#define MAX_STATIONS 4
// An attendant's "next coins -> tablet N" lasts this long after the selection
// or the last coin, so a forgotten selection cannot misroute later coins.
#define SELECTION_TTL_S 90UL
// Largest single free-time grant accepted from the dashboard.
#define MAX_ADMIN_CREDIT_S (4UL * 3600UL)

// ---------------------------------------------------------------- pins
// NodeMCU / Wemos D1 mini labels in comments.
#define COIN_PIN 5      // D1 / GPIO5  — Allan coin slot COIN signal (active-low, 3.3 V max!)
#define LCD_SDA_PIN 4   // D2 / GPIO4
#define LCD_SCL_PIN 14  // D5 / GPIO14
#define BUTTON_PIN 0    // D3 / GPIO0  — on-board FLASH button (press only AFTER boot)

// If your coin slot output is open-collector and you have no external pull-up
// to 3.3 V, enable the ESP8266's weak internal pull-up (~30-100 kΩ).
// An external 4.7-10 kΩ pull-up to 3.3 V is recommended for noisy cabinets.
#define COIN_USE_INTERNAL_PULLUP 1

// ---------------------------------------------------------------- pulse filtering
// Allan/universal coin slots emit one LOW pulse per credit unit; the pulse
// width is selectable on most units (FAST ~20-30 ms, MEDIUM ~50 ms, SLOW ~100 ms).
// A pulse is accepted only if its LOW width is inside this window.
#define PULSE_MIN_WIDTH_US 10000UL   // 10 ms — shorter LOW glitches are noise
#define PULSE_MAX_WIDTH_US 150000UL  // 150 ms — longer LOW means wiring fault / jam
// Pulses closer together than this gap (falling edge to falling edge) are rejected.
#define PULSE_MIN_GAP_US 15000UL
// A coin's pulse train is complete when no pulse arrives for this long.
// Must be longer than the slot's gap between pulses (typically 50-150 ms).
#define PULSE_GROUP_TIMEOUT_MS 400UL

// ---------------------------------------------------------------- rates
// Default until the cloud dashboard sends a newer configuration version.
#define DEFAULT_SECONDS_PER_PULSE 240UL  // 1 pulse = 4 minutes
#define MAX_SESSION_SECONDS (7UL * 24UL * 3600UL)  // hard cap on accumulated time

// ---------------------------------------------------------------- persistence
// When 1, the remaining time is checkpointed to flash and restored after a
// power loss or reset. The restored value can be up to CHECKPOINT_INTERVAL_S
// higher than the true value, and time while powered off is NOT deducted
// (there is no battery-backed clock). When 0, paid time is lost on restart.
#define RESUME_AFTER_RESTART 1
// Flash writes happen on each coin, on expiry, and at most this often while
// a session runs (never every second). 60 s ≈ 1 small write per minute.
#define CHECKPOINT_INTERVAL_S 60UL

// ---------------------------------------------------------------- networking
#define LOCAL_HTTP_PORT 80
#define DEFAULT_API_BASE "https://vendo-kiosk.ebnleadgen.online/api/v1"
#define DEFAULT_SYNC_INTERVAL_S 15UL
// Fast poll for the attendant's selection and dashboard commands (kept-alive TLS).
#define POLL_INTERVAL_MS 2000UL
#define POLL_BACKOFF_MAX_MS 30000UL
// Dashboard command ids applied recently (also kept across restarts) so a
// re-sent command is never applied twice.
#define APPLIED_CMD_RING 16
#define MIN_SYNC_GAP_MS 3000UL          // earliest re-sync after a coin
#define CLOUD_BACKOFF_MAX_S 300UL
#define HTTP_TIMEOUT_MS 8000

// Unsent cloud events kept in RAM. On overflow the OLDEST event is dropped
// and dropped_events is incremented (reported to the dashboard). Local paid
// time is never affected by cloud buffering.
#define EVENT_BUFFER_SIZE 48
#define EVENTS_PER_SYNC 16

// ---------------------------------------------------------------- status.php upload (existing database)
// Compatible with the original sketch: POSTs {"device_id","boot_id","sequence",
// "remaining_seconds","last_pulses"} with "Authorization: Bearer <token>" to
// api/status.php, which fills device_status (read by /api/kiosk-status.php).
// Enabled when a status upload token is entered in the setup portal.
#define DEFAULT_STATUS_URL "https://vendo-kiosk.ebnleadgen.online/api/status.php"
#define DEFAULT_STATUS_DEVICE_ID "vendo-001"
#define STATUS_MIN_GAP_MS 1000UL           // after a coin / expiry: upload right away
#define STATUS_RUNNING_INTERVAL_MS 10000UL // while time is running
#define STATUS_IDLE_INTERVAL_MS 30000UL    // heartbeat while idle (browser "stale" after 60 s)
#define STATUS_RETRY_MS 5000UL             // after a failed upload

// ---------------------------------------------------------------- pairing / admin
#define PAIRING_WINDOW_MS 120000UL
#define PAIRING_MAX_ATTEMPTS 5
#define BUTTON_INFO_MAX_MS 1000UL    // short press: next tablet selection (offline fallback)
#define BUTTON_INFO_HOLD_MS 1000UL   // hold 1-3 s: show IP / device ID
#define BUTTON_PAIR_HOLD_MS 3000UL   // hold 3 s: open phone pairing window
#define BUTTON_SETUP_HOLD_MS 10000UL // hold 10 s: restart into Wi-Fi setup portal

// ---------------------------------------------------------------- LCD
#define LCD_COLS 20
#define LCD_ROWS 4
#define LCD_REFRESH_MS 200UL
