# vendo_status_uploader (faster version of the original status.php sketch)

Same wiring (coin D1, LCD SDA D2 / SCL D5), same pulse filter, and the same
JSON sent to `api/status.php`, so the server does not change.

## Setup
1. Copy `secrets.example.h` to `secrets.h` and fill in Wi-Fi and the 64-character
   upload token. `secrets.h` is git-ignored — never paste it anywhere.
2. Arduino IDE: board *NodeMCU 1.0* or *LOLIN(WEMOS) D1 R2 & mini*, library
   *LiquidCrystal I2C* (Frank de Brabander). Upload.

## Why coins now show up faster

| Step | Original | This version |
|---|---|---|
| End of coin pulses → credited | 500 ms | 400 ms (`COIN_TIMEOUT_US`) |
| Credited → upload starts | up to 10 s (waited for the upload timer) | immediately (≥1 s after the previous upload) |
| HTTPS upload | new TLS handshake every time, ~1–3 s | kept-alive connection / cached TLS session, typically 0.1–0.5 s |
| Database → browser | — | ≈0.3 s (long-poll in `/api/kiosk-status.php`) |
| **Coin → browser** | **≈2–13 s** | **≈1–2 s** (estimate; measure with the serial log, it prints the upload time) |

Also: heartbeat every 30 s while idle (so the browser does not show STALE when
nobody is playing), LCD shows `Time: HH:MM:SS`, failed uploads retry after 5 s.

`sequence` still counts uploads (unchanged for `status.php`); the browser now
detects coins from jumps in remaining time.

If you lower `COIN_TIMEOUT_US` further, check in the serial monitor that one
5-peso coin is still counted as one 5-pulse coin.
