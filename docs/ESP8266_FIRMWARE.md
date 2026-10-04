# ESP8266 coin controller — hardware and firmware

Firmware: `firmware/vendo_coin_controller/` (Arduino sketch).
Prebuilt binaries (no secrets inside): `dist/firmware/*.bin`.

## Parts

* NodeMCU 1.0 (ESP-12E) **or** Wemos/LOLIN D1 mini
* Allan (universal) multi-coin acceptor with pulse output (12 V model is typical)
* 20x4 character LCD with PCF8574 I2C backpack (address 0x27 or 0x3F, auto-detected)
* Power supplies (see below), wires, optional logic-level converter

## Wiring

| Signal | ESP8266 pin | Board label | Notes |
|---|---|---|---|
| Coin COIN/SIGNAL | GPIO5 | **D1** | active-low pulse, **must be ≤ 3.3 V** |
| LCD SDA | GPIO4 | **D2** | I2C data |
| LCD SCL | GPIO14 | **D5** | I2C clock |
| Pair/setup button | GPIO0 | D3 (on-board FLASH) | press only after boot |
| GND | GND | G | **common ground for everything** |

The firmware calls `Wire.begin(4, 14)` before `lcd.init()` so the LCD library
does not grab the ESP8266's default SCL pin (GPIO5 = D1, the coin input).

### Power — use rated supplies and a common ground

* **Coin acceptor**: its rated supply, usually **12 V DC, ≥ 1 A** (check the
  label; the coil draws a surge when it rejects a coin).
* **ESP8266 board**: 5 V via USB or the 5V/VIN pin from a **regulated 5 V
  supply rated ≥ 1 A** (a 12 V→5 V buck converter is fine). Do not feed 12 V
  into the board.
* **LCD**: 5 V from the same 5 V rail (backlight ~ 100–200 mA).
* Connect **all grounds together** (coin acceptor GND, 5 V supply GND, ESP GND,
  LCD GND). Without a common ground the pulse signal is meaningless and noisy.

### Coin signal level — the ESP8266 is NOT 5 V tolerant

Measure the COIN output with a multimeter while the slot is idle:

* **Open-collector / open-drain output** (common on Allan units; idle reads ~0 V
  or floats when disconnected): connect it directly to D1 and pull it up to
  **3.3 V** (internal pull-up is enabled by `COIN_USE_INTERNAL_PULLUP 1`; an
  external **10 kΩ to 3.3 V** is better in an electrically noisy cabinet).
* **Output idles at 5 V or 12 V**: you **must** level-shift. Options:
  * NPN transistor or optocoupler (PC817): coin output drives the LED side
    through a resistor (e.g. 1 kΩ at 12 V); the transistor side pulls D1 to GND
    with a 10 kΩ pull-up to 3.3 V. This also isolates the 12 V side (preferred).
  * Resistor divider for 5 V only: 10 kΩ (top) + 20 kΩ (bottom) → 3.3 V.
    Not suitable for 12 V signals.

The firmware treats a **LOW** pulse as one credit unit. If you use an
inverting optocoupler stage, make sure the result at D1 is still active-low.

### LCD I2C pull-ups

Most PCF8574 backpacks have 4.7 kΩ pull-ups to **VCC**. If the backpack is
powered from 5 V, SDA/SCL idle at 5 V — over the ESP8266's limit. Either:

* remove/disable the backpack pull-ups and add 4.7 kΩ pull-ups to **3.3 V**, or
* use a bidirectional I2C level shifter (BSS138 type) between 3.3 V and 5 V, or
* power the backpack from 3.3 V if your LCD is a 3.3 V model (many 5 V LCDs
  have poor contrast at 3.3 V).

## Coin slot settings

Program the Allan slot so each coin produces the desired number of pulses
(e.g. 1 peso = 1 pulse, 5 peso = 5 pulses, 10 peso = 10 pulses, 20 peso = 20
pulses). Set the pulse speed to **Medium (≈50 ms)** or **Slow (≈100 ms)**.

Tunable in `config.h`:

| Setting | Default | Meaning |
|---|---|---|
| `PULSE_MIN_WIDTH_US` | 10 ms | shorter LOW glitches are ignored |
| `PULSE_MAX_WIDTH_US` | 150 ms | longer LOW (stuck line) is ignored |
| `PULSE_MIN_GAP_US` | 15 ms | minimum falling-edge spacing |
| `PULSE_GROUP_TIMEOUT_MS` | 400 ms | silence that ends one coin's pulse train |
| `DEFAULT_SECONDS_PER_PULSE` | 240 | 1 pulse = 4 min until the cloud sends a rate |
| `RESUME_AFTER_RESTART` | 1 | restore remaining time after reboot (see below) |
| `CHECKPOINT_INTERVAL_S` | 60 | flash checkpoint period while running |
| `EVENT_BUFFER_SIZE` | 48 | unsent cloud events kept in RAM |

The interrupt handler (`onCoinEdge`, `IRAM_ATTR`) only timestamps edges and
validates the pulse width; grouping, crediting, LCD, flash and networking all
happen in `loop()`.

Rates: 1 pulse = 4 min, 5 = 20 min, 10 = 40 min, 20 = 80 min. Coins during a
session extend it.

## LCD

```
INSERT COIN          ← or TIMER RUNNING
Time: 00:19:42
Last added: 20 min
Last pulses: 5
```

Only changed rows are rewritten; the screen is cleared once at start-up.
Temporary admin screens: short press FLASH → rows 3–4 show IP and device ID for
10 s; pairing mode → row 3 shows `PAIR CODE: nnnnnn`, row 4 the IP; setup mode
shows the access-point name and password.

## Building and flashing

Arduino IDE 2.x:
1. Boards Manager → install **esp8266 by ESP8266 Community** (tested 3.1.2).
2. Library Manager → install **LiquidCrystal I2C** by Frank de Brabander (1.1.x).
   No JSON library is needed.
3. Open `firmware/vendo_coin_controller/vendo_coin_controller.ino`, select
   *NodeMCU 1.0 (ESP-12E Module)* or *LOLIN(WEMOS) D1 R2 & mini*, upload.

arduino-cli:
```
arduino-cli compile --fqbn esp8266:esp8266:nodemcuv2 firmware/vendo_coin_controller
arduino-cli upload  --fqbn esp8266:esp8266:nodemcuv2 -p COM5 firmware/vendo_coin_controller
```
Or flash a prebuilt binary with esptool:
`esptool.py --port COM5 write_flash 0x0 dist/firmware/vendo_coin_controller-1.0.0-nodemcuv2.bin`

## First-time setup

1. Power on. With no Wi-Fi saved the LCD shows `WIFI SETUP MODE`, an access
   point `VendoCoin-xxxxxx` and an 8-digit password.
2. Join that Wi-Fi with a phone/laptop, open `http://192.168.4.1`.
3. Enter your shop Wi-Fi name/password, a controller name, and (optionally) a
   **coin controller enrollment code** from the dashboard. Save → it restarts.
4. Give the controller a fixed IP: create a **DHCP reservation** for its MAC in
   your router (recommended), so the phone always finds it.
5. Pair the phone: short-press FLASH to see the IP; hold FLASH **3 s** to show
   the pairing code; enter both in the phone's Admin → Coin controller.

To change Wi-Fi later, hold FLASH **10 s** (restarts into setup mode). Paid time
is checkpointed first.

## Switching from the original `status.php` sketch (firmware 1.1.0)

This firmware replaces the original sketch (same pins, same LCD, same coin
filtering idea) and adds the signed local connection the Android kiosk needs.
It **keeps uploading to your existing `api/status.php`** with exactly the same
JSON, so `device_status`, the browser demo (`/api/kiosk-status.php`) and anything
else reading that table keep working.

| | Original sketch | This firmware |
|---|---|---|
| Android kiosk can pair | no | yes (local, ~1 s, works without internet) |
| Upload to `status.php` | every 10 s, coin waits for the timer | immediately after a coin, 10 s while running, 30 s idle heartbeat |
| HTTPS | new handshake each upload | kept-alive connection + cached TLS session |
| Secrets | in the source code | entered in the setup page, stored on the controller |

Steps:
1. **Rotate the upload token** that was in the old sketch (it was shared in
   plain text). Update it wherever `status.php` checks it.
2. Flash `dist/firmware/vendo_coin_controller-1.1.0-nodemcuv2.bin` (or
   `-d1_mini.bin`), or build `firmware/vendo_coin_controller` in Arduino IDE.
3. The LCD shows `WIFI SETUP MODE`, an access point `VendoCoin-xxxxxx` and its
   password. Join it, open `http://192.168.4.1` and fill in:
   * Wi-Fi name and password;
   * **Upload to existing status.php**: URL (pre-filled
     `https://vendo-kiosk.ebnleadgen.online/api/status.php`), device ID
     (`vendo-001`), and the **new** 64-character upload token;
   * leave "Cloud enrollment code" empty unless you deploy the `/api/v1` dashboard.
4. Save. After restart the serial log (115200 baud) shows
   `[status] upload #1: HTTP 200 in … ms`. A coin should appear in the browser
   demo within about 1–2 seconds.
5. Pair the phone: short-press FLASH → LCD shows the IP; hold FLASH 3 s → LCD
   shows a 6-digit code; on the phone: Admin → Coin controller → enter both.
6. Give the controller a DHCP reservation in the router so its IP stays the same.

Changing the upload settings without setup mode: connect USB, open a serial
terminal at 115200 baud and send one line (the value is saved to flash and
never printed back):

```
status_token=<64-character token>
status_device_id=vendo-001
status_url=https://vendo-kiosk.ebnleadgen.online/api/status.php
```

The log then shows `[config] status_token updated and saved` followed by the
next `[status] upload … HTTP 200`. While the LCD is unreadable, the serial log
also prints the controller's IP after joining Wi-Fi and the 6-digit code when
the pairing window opens.

The local status the phone reads includes `"status_upload": "ok|error|unauthorized|waiting_for_time|disabled"`
for diagnostics. `boot_id` sent to `status.php` keeps the original
`chipid-random-random` format; `sequence` still counts uploads.

`firmware/vendo_status_uploader/` (the sped-up original sketch) remains as a
fallback if you ever need the cloud-only behaviour without a phone.

## Persistence and power loss

* **Paid time survives a restart** by default (`RESUME_AFTER_RESTART 1`): the
  remaining seconds are checkpointed on every coin, at expiry and every 60 s
  while running. After power loss the controller resumes from the last
  checkpoint, so a customer may gain up to 60 s, and **time while the power was
  off is not deducted** (no battery-backed clock). Set it to `0` to discard
  time on restart instead (customers lose time on power cuts).
* Flash wear: at most ~1 small write per minute while a session runs, nothing
  while idle. LittleFS spreads writes across the flash.
* Unsent cloud events live in RAM and are **lost on power loss**. The paid time
  itself is not affected; the dashboard simply misses those records. A UPS for
  the controller avoids both issues.

## Cloud TLS

HTTPS uses BearSSL with full certificate validation against the ISRG roots in
`certs.h` (`setInsecure()` is never used). The clock is set by NTP first (the
LCD/serial shows `waiting_for_time` until then). If the hosting CA ever changes
to a non-ISRG CA, add its root to `certs.h` and reflash. A TLS handshake takes
1–3 s on the ESP8266; coins are still counted by the interrupt during that time
and the phone tolerates the short pause.
