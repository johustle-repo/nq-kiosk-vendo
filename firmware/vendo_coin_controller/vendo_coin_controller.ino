/*
  Vendo Kiosk — ESP8266 coin controller (one coin box, up to 4 tablets)
  =====================================================================
  Board:   NodeMCU 1.0 (ESP-12E) or LOLIN(WEMOS) D1 mini, ESP8266 Arduino core 3.1.x
  Libs:    LiquidCrystal_I2C 1.1.x (Frank de Brabander). No JSON library needed.

  This controller is the AUTHORITY for paid time on every tablet it serves:
   - counts coin pulses (IRAM interrupt), groups them into one coin, and credits
     them to the tablet the attendant selected on the dashboard (or the FLASH
     button when offline). Coins with no selection are HELD, never lost, until
     the attendant assigns them;
   - keeps an independent timer per tablet (station 1..MAX_STATIONS);
   - serves an authenticated local HTTP API so each paired tablet can read its
     own remaining time (responses are HMAC-signed with that tablet's key over
     a fresh tablet nonce);
   - talks to the dashboard over verified HTTPS on ONE kept-alive connection:
     a fast poll (selection + commands), event sync, and the status.php upload.
  Time can be added by coins, and by audited dashboard commands
  (add time / assign held coins), nothing else.

  See docs/ESP8266_FIRMWARE.md for wiring, power and level shifting.
*/

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClientSecureBearSSL.h>
#include <LittleFS.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <time.h>
#include <bearssl/bearssl.h>

#include "config.h"
#include "types.h"
#include "certs.h"

// ============================================================ ISR state
// Only these variables are touched inside the interrupt handler.
volatile uint32_t isrAcceptedPulses = 0;  // total accepted pulses since boot
volatile uint32_t isrRejectedPulses = 0;  // glitches / out-of-window pulses
volatile uint32_t isrLastAcceptUs = 0;    // micros() of last accepted pulse end
volatile uint32_t isrFallUs = 0;
volatile uint32_t isrLastFallUs = 0;
volatile bool isrInPulse = false;

// Short handler: timestamps edges and validates pulse width. No LCD, Serial,
// networking, flash or heap use here.
void IRAM_ATTR onCoinEdge() {
  const uint32_t now = micros();
  const bool low = !GPIP(COIN_PIN);
  if (low) {
    if ((uint32_t)(now - isrLastFallUs) < PULSE_MIN_GAP_US) {
      isrInPulse = false;  // too soon after the previous pulse: ignore it
      isrRejectedPulses++;
    } else {
      isrInPulse = true;
      isrFallUs = now;
    }
    isrLastFallUs = now;
  } else if (isrInPulse) {
    isrInPulse = false;
    const uint32_t width = now - isrFallUs;
    if (width >= PULSE_MIN_WIDTH_US && width <= PULSE_MAX_WIDTH_US) {
      isrAcceptedPulses++;
      isrLastAcceptUs = now;
    } else {
      isrRejectedPulses++;
    }
  }
}

// ============================================================ persistent settings
Settings settings;
Station stations[MAX_STATIONS + 1];  // index 1..MAX_STATIONS (0 unused)

static const char *SETTINGS_FILE = "/settings.txt";
static const char *SESSION_FILE = "/session.txt";
static const char *FORCE_SETUP_FILE = "/force_setup";

// ============================================================ runtime state
LiquidCrystal_I2C *lcd = nullptr;
ESP8266WebServer server(LOCAL_HTTP_PORT);
BearSSL::X509List *trustAnchors = nullptr;

String deviceId;  // "vk-" + chip id
String bootId;    // random per boot: lets the tablets and cloud detect restarts

bool setupMode = false;
String apPassword;

uint32_t eventSeq = 0;  // event sequence number for this boot
uint32_t committedPulses = 0;
uint64_t lastCheckpointMs = 0;
bool resumedFromCheckpoint = false;

// Coins inserted while no tablet was selected (pesos = pulses).
uint32_t heldPulses = 0;
// Where the next coins go: 0 = nobody (coins are held).
uint8_t selStation = 0;
uint32_t selTtlS = 0;  // lifetime of the current selection, renewed by each coin
uint64_t selUntilMs = 0;
uint32_t selVersionApplied = 0;  // dashboard selection version last applied
uint8_t lastCoinStation = 0;     // for the LCD "last coin" line
int8_t relayOverride = -1;       // serial "relay=on/off" test: -1 = automatic
uint32_t lastCoinPulses = 0;

// Dashboard commands applied (ring, persisted) and waiting to be acknowledged.
uint32_t appliedCmds[APPLIED_CMD_RING] = {0};
uint8_t appliedCmdNext = 0;
struct Ack {
  uint32_t id;
  const char *result;
};
Ack pendingAcks[APPLIED_CMD_RING];
uint8_t pendingAckCount = 0;

// Cloud event buffer (bounded ring)
Event events[EVENT_BUFFER_SIZE];
uint8_t evStart = 0, evCount = 0;
uint32_t droppedEvents = 0;

// One verified TLS connection, kept alive and shared by poll, sync and status upload.
BearSSL::WiFiClientSecure netClient;
HTTPClient netHttp;
BearSSL::Session netSession;  // cached TLS session for fast reconnects

CloudState cloudState = CLOUD_DISABLED;  // enrollment / event sync
CloudState pollState = CLOUD_DISABLED;   // fast poll
CloudState statusState = CLOUD_DISABLED; // status.php upload
uint64_t nextSyncMs = 0;
uint64_t nextPollMs = 0;
uint32_t cloudFailures = 0;
uint32_t pollFailures = 0;
uint64_t lastCloudOkMs = 0;

// status.php upload state
char statusBootId[40];   // same format as the original sketch
uint32_t statusSequence = 0;
bool statusUploadNeeded = true;
bool statusLastFailed = false;
uint64_t lastStatusUploadMs = 0;

// Pairing / admin
bool pairingOpen = false;
uint64_t pairingUntilMs = 0;
uint8_t pairingAttempts = 0;
char pairingCode[7] = {0};
uint64_t infoUntilMs = 0;

// ============================================================ helpers
uint64_t millis64() {
  static uint32_t last = 0;
  static uint64_t high = 0;
  const uint32_t now = millis();
  if (now < last) high += (1ULL << 32);
  last = now;
  return high + now;
}

String u64str(uint64_t v) {
  char buf[21];
  char *p = buf + sizeof(buf) - 1;
  *p = '\0';
  do {
    *--p = '0' + (v % 10);
    v /= 10;
  } while (v);
  return String(p);
}

String randomHex(size_t bytes) {
  static const char hexd[] = "0123456789abcdef";
  String s;
  s.reserve(bytes * 2);
  for (size_t i = 0; i < bytes; i++) {
    uint8_t b = (uint8_t)(ESP.random() & 0xFF);  // hardware RNG
    s += hexd[b >> 4];
    s += hexd[b & 0x0F];
  }
  return s;
}

bool hexToBytes(const String &hex, uint8_t *out, size_t len) {
  if (hex.length() != len * 2) return false;
  for (size_t i = 0; i < len; i++) {
    char hi = hex[2 * i], lo = hex[2 * i + 1];
    auto nib = [](char c) -> int {
      if (c >= '0' && c <= '9') return c - '0';
      if (c >= 'a' && c <= 'f') return c - 'a' + 10;
      if (c >= 'A' && c <= 'F') return c - 'A' + 10;
      return -1;
    };
    int h = nib(hi), l = nib(lo);
    if (h < 0 || l < 0) return false;
    out[i] = (uint8_t)((h << 4) | l);
  }
  return true;
}

// HMAC-SHA256 with a tablet's pairing key, as lowercase hex ("" if no key).
String hmacHex(const String &keyHex, const String &message) {
  uint8_t key[32];
  if (!hexToBytes(keyHex, key, sizeof(key))) return String();
  br_hmac_key_context kc;
  br_hmac_key_init(&kc, &br_sha256_vtable, key, sizeof(key));
  br_hmac_context ctx;
  br_hmac_init(&ctx, &kc, 0);
  br_hmac_update(&ctx, message.c_str(), message.length());
  uint8_t out[32];
  br_hmac_out(&ctx, out);
  static const char hexd[] = "0123456789abcdef";
  String s;
  s.reserve(64);
  for (uint8_t b : out) {
    s += hexd[b >> 4];
    s += hexd[b & 0x0F];
  }
  memset(key, 0, sizeof(key));
  return s;
}

bool constantTimeEquals(const String &a, const String &b) {
  if (a.length() != b.length()) return false;
  uint8_t diff = 0;
  for (size_t i = 0; i < a.length(); i++) diff |= (uint8_t)(a[i] ^ b[i]);
  return diff == 0;
}

bool isHex(const String &s, size_t minLen, size_t maxLen) {
  if (s.length() < minLen || s.length() > maxLen) return false;
  for (size_t i = 0; i < s.length(); i++) {
    if (!isxdigit((unsigned char)s[i])) return false;
  }
  return true;
}

// Keep only printable ASCII without quotes/backslashes (safe for JSON and our settings file).
String sanitize(const String &in, size_t maxLen) {
  String out;
  for (size_t i = 0; i < in.length() && out.length() < maxLen; i++) {
    char c = in[i];
    if (c >= 0x20 && c < 0x7F && c != '"' && c != '\\') out += c;
  }
  return out;
}

String hms(uint32_t s) {
  char buf[12];
  snprintf(buf, sizeof(buf), "%02lu:%02lu:%02lu", (unsigned long)(s / 3600), (unsigned long)((s % 3600) / 60), (unsigned long)(s % 60));
  return String(buf);
}

uint32_t unixTimeOrZero() {
  time_t t = time(nullptr);
  return t > 1700000000 ? (uint32_t)t : 0;
}

bool validStation(long n) { return n >= 1 && n <= MAX_STATIONS; }

// ============================================================ settings storage (LittleFS)
// Format: key=value per line. Written only when something changes.
bool saveSettings() {
  File f = LittleFS.open(SETTINGS_FILE, "w");
  if (!f) return false;
  f.printf("wifi_ssid=%s\n", settings.wifiSsid.c_str());
  f.printf("wifi_pass=%s\n", settings.wifiPass.c_str());
  f.printf("device_name=%s\n", settings.deviceName.c_str());
  f.printf("api_base=%s\n", settings.apiBase.c_str());
  f.printf("cloud_token=%s\n", settings.cloudToken.c_str());
  f.printf("enroll_code=%s\n", settings.enrollCode.c_str());
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    f.printf("pair_key_%u=%s\n", i, stations[i].pairKeyHex.c_str());
    f.printf("paired_phone_%u=%s\n", i, stations[i].pairedPhoneId.c_str());
    f.printf("charge_%u=%u\n", i, stations[i].chargeWanted ? 1 : 0);
  }
  f.printf("seconds_per_pulse=%lu\n", (unsigned long)settings.secondsPerPulse);
  f.printf("rate_version=%lu\n", (unsigned long)settings.rateVersion);
  f.printf("sync_interval_s=%lu\n", (unsigned long)settings.syncIntervalS);
  f.printf("status_url=%s\n", settings.statusUrl.c_str());
  f.printf("status_device_id=%s\n", settings.statusDeviceId.c_str());
  f.printf("status_token=%s\n", settings.statusToken.c_str());
  f.close();
  return true;
}

void loadSettings() {
  File f = LittleFS.open(SETTINGS_FILE, "r");
  if (!f) return;
  while (f.available()) {
    String line = f.readStringUntil('\n');
    int eq = line.indexOf('=');
    if (eq <= 0) continue;
    String k = line.substring(0, eq);
    String v = line.substring(eq + 1);
    if (k == "wifi_ssid") settings.wifiSsid = v;
    else if (k == "wifi_pass") settings.wifiPass = v;
    else if (k == "device_name" && v.length()) settings.deviceName = v;
    else if (k == "api_base" && v.startsWith("https://")) settings.apiBase = v;
    else if (k == "cloud_token") settings.cloudToken = v;
    else if (k == "enroll_code") settings.enrollCode = v;
    // Firmware 1.x had a single phone: it becomes tablet 1.
    else if (k == "pair_key") stations[1].pairKeyHex = v;
    else if (k == "paired_phone") stations[1].pairedPhoneId = v;
    else if (k.startsWith("pair_key_") && validStation(k.substring(9).toInt())) stations[k.substring(9).toInt()].pairKeyHex = v;
    else if (k.startsWith("paired_phone_") && validStation(k.substring(13).toInt())) stations[k.substring(13).toInt()].pairedPhoneId = v;
    else if (k.startsWith("charge_") && validStation(k.substring(7).toInt())) stations[k.substring(7).toInt()].chargeWanted = v == "1";
    else if (k == "seconds_per_pulse") {
      uint32_t s = v.toInt();
      if (s >= 10 && s <= 3600) settings.secondsPerPulse = s;
    } else if (k == "rate_version") settings.rateVersion = v.toInt();
    else if (k == "status_url" && v.startsWith("https://")) settings.statusUrl = v;
    else if (k == "status_device_id" && v.length()) settings.statusDeviceId = v;
    else if (k == "status_token") settings.statusToken = v;
    else if (k == "sync_interval_s") {
      uint32_t s = v.toInt();
      if (s >= 5 && s <= 300) settings.syncIntervalS = s;
    }
  }
  f.close();
}

// ============================================================ charger relay (D6)
bool chargeRelayOn() {
  if (relayOverride >= 0) return relayOverride == 1;
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    if (stations[i].chargeWanted && stations[i].pairKeyHex.length()) return true;
  }
  return false;
}

void applyChargeRelay() {
  static int8_t applied = -1;
  const bool on = chargeRelayOn();
  digitalWrite(CHARGE_RELAY_PIN, (on != (bool)CHARGE_RELAY_ACTIVE_LOW) ? HIGH : LOW);
  if (applied != (int8_t)on) {
    applied = on;
    Serial.printf("[relay] charger %s\n", on ? "ON" : "OFF");
  }
}

// ============================================================ tablets (authoritative time)
uint32_t remainingSeconds(uint8_t n) {
  const Station &s = stations[n];
  if (!s.running) return 0;
  const uint64_t now = millis64();
  if (now >= s.endMs) return 0;
  return (uint32_t)((s.endMs - now + 999) / 1000);
}

bool anyRunning() {
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    if (remainingSeconds(i)) return true;
  }
  return false;
}

bool selectionActive() { return selStation != 0 && millis64() < selUntilMs; }

// With exactly one tablet paired there is nothing to choose: its coins go
// straight to it, as on a single-tablet kiosk. Returns 0 otherwise.
uint8_t soleTablet() {
  uint8_t found = 0;
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    if (stations[i].pairKeyHex.isEmpty()) continue;
    if (found) return 0;
    found = i;
  }
  return found;
}

// Where a coin inserted now goes: the attendant's selection, else the only paired tablet, else nobody (held).
uint8_t coinTarget() { return selectionActive() ? selStation : soleTablet(); }

uint32_t selectionTtlS() { return selectionActive() ? (uint32_t)((selUntilMs - millis64() + 999) / 1000) : 0; }

void setSelection(uint8_t n, uint32_t ttlS) {
  selStation = validStation(n) && ttlS ? n : 0;
  selTtlS = selStation ? ttlS : 0;
  selUntilMs = selStation ? millis64() + (uint64_t)ttlS * 1000ULL : 0;
  Serial.printf("[select] next coins -> %s\n", selStation ? ("tablet " + String(selStation)).c_str() : "held");
}

// Checkpoint: each tablet's remaining time, held coins and recently applied
// dashboard commands, so a restart neither loses paid time nor re-applies a
// command whose acknowledgement had not reached the dashboard yet.
void saveCheckpoint() {
  File f = LittleFS.open(SESSION_FILE, "w");
  if (!f) return;
#if RESUME_AFTER_RESTART
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    f.printf("s%u=%lu,%lu\n", i, (unsigned long)remainingSeconds(i), (unsigned long)stations[i].sessionNo);
  }
#endif
  f.printf("held=%lu\n", (unsigned long)heldPulses);  // money, always kept
  f.print("cmds=");
  for (uint8_t i = 0; i < APPLIED_CMD_RING; i++) f.printf("%lu,", (unsigned long)appliedCmds[i]);
  f.print("\n");
  f.close();
  lastCheckpointMs = millis64();
}

void restoreCheckpoint() {
  File f = LittleFS.open(SESSION_FILE, "r");
  if (!f) return;
  const uint64_t now = millis64();
  while (f.available()) {
    String line = f.readStringUntil('\n');
    uint8_t n = 0;
    uint32_t remaining = 0, no = 0;
    if (line.startsWith("remaining=")) {  // firmware 1.x: tablet 1
      n = 1;
      remaining = line.substring(10).toInt();
    } else if (line.startsWith("session_no=")) {
      stations[1].sessionNo = line.substring(11).toInt();
    } else if (line.length() > 3 && line[0] == 's' && line[2] == '=' && validStation(line[1] - '0')) {
      n = line[1] - '0';
      const int comma = line.indexOf(',');
      remaining = line.substring(3, comma < 0 ? line.length() : comma).toInt();
      if (comma > 0) no = line.substring(comma + 1).toInt();
      stations[n].sessionNo = no;
    } else if (line.startsWith("held=")) {
      heldPulses = line.substring(5).toInt();
    } else if (line.startsWith("cmds=")) {
      int from = 5;
      for (uint8_t i = 0; i < APPLIED_CMD_RING; i++) {
        const int comma = line.indexOf(',', from);
        if (comma < 0) break;
        appliedCmds[i] = line.substring(from, comma).toInt();
        from = comma + 1;
      }
    }
#if RESUME_AFTER_RESTART
    if (validStation(n) && remaining > 0 && remaining <= MAX_SESSION_SECONDS) {
      stations[n].running = true;
      stations[n].endMs = now + (uint64_t)remaining * 1000ULL;
      resumedFromCheckpoint = true;
    }
#endif
  }
  f.close();
}

void pushEvent(const Event &e) {
  if (evCount == EVENT_BUFFER_SIZE) {
    // Overflow: drop the oldest unsent event (documented). Local time is unaffected.
    evStart = (evStart + 1) % EVENT_BUFFER_SIZE;
    evCount--;
    droppedEvents++;
  }
  events[(evStart + evCount) % EVENT_BUFFER_SIZE] = e;
  evCount++;
}

void reportSoon() {
  statusUploadNeeded = true;
  const uint64_t soon = millis64() + MIN_SYNC_GAP_MS;
  if (nextSyncMs > soon) nextSyncMs = soon;
}

// Adds time to tablet n. type: EV_CREDIT (coins), EV_ASSIGN (held coins) or EV_ADMIN_CREDIT.
void addTime(uint8_t n, uint32_t pulses, uint32_t seconds, uint8_t type, uint32_t commandId) {
  Station &s = stations[n];
  const uint64_t now = millis64();
  if (!s.running || s.endMs <= now) {
    s.running = true;
    s.sessionNo++;
    s.endMs = now;
  }
  s.endMs += (uint64_t)seconds * 1000ULL;  // additional coins extend the session
  const uint64_t cap = now + (uint64_t)MAX_SESSION_SECONDS * 1000ULL;
  if (s.endMs > cap) s.endMs = cap;
  s.lastAddedS = seconds;
  if (pulses) s.lastPulses = pulses;
  eventSeq++;
  Event e{eventSeq, type, n, s.sessionNo, (uint16_t)min<uint32_t>(pulses, 65535), seconds, settings.rateVersion,
          remainingSeconds(n), now, unixTimeOrZero(), commandId};
  pushEvent(e);
  saveCheckpoint();
  Serial.printf("[time] tablet %u +%lu s (%lu pulse(s), type %u), remaining %lu s, seq %lu\n", n, (unsigned long)seconds,
                (unsigned long)pulses, type, (unsigned long)remainingSeconds(n), (unsigned long)eventSeq);
  reportSoon();
}

void creditCoin(uint32_t pulses) {
  lastCoinPulses = pulses;
  const uint8_t target = coinTarget();
  if (target) {
    lastCoinStation = target;
    if (selectionActive()) selUntilMs = millis64() + (uint64_t)selTtlS * 1000ULL;  // keep it while coins keep coming
    addTime(target, pulses, pulses * settings.secondsPerPulse, EV_CREDIT, 0);
    return;
  }
  // Nobody selected: keep the money and let the attendant assign it.
  lastCoinStation = 0;
  heldPulses += pulses;
  eventSeq++;
  Event e{eventSeq, EV_HELD, 0, 0, (uint16_t)min<uint32_t>(pulses, 65535), 0, settings.rateVersion, 0, millis64(), unixTimeOrZero(), 0};
  pushEvent(e);
  saveCheckpoint();
  Serial.printf("[coin] %lu pulse(s) held (no tablet selected), held total %lu\n", (unsigned long)pulses, (unsigned long)heldPulses);
  reportSoon();
}

void assignHeld(uint8_t n, uint32_t commandId) {
  if (!heldPulses) return;
  const uint32_t pulses = heldPulses;
  heldPulses = 0;
  lastCoinStation = n;
  addTime(n, pulses, pulses * settings.secondsPerPulse, EV_ASSIGN, commandId);  // also saves the checkpoint
}

void processPulses() {
  noInterrupts();
  const uint32_t total = isrAcceptedPulses;
  const uint32_t lastUs = isrLastAcceptUs;
  interrupts();
  const uint32_t pending = total - committedPulses;
  if (pending == 0) return;
  // Wait until the coin's pulse train is complete, then credit it as one coin.
  if ((uint32_t)(micros() - lastUs) < PULSE_GROUP_TIMEOUT_MS * 1000UL) return;
  committedPulses = total;
  creditCoin(pending);
}

void endSession(uint8_t n, uint8_t type, uint32_t commandId) {
  Station &s = stations[n];
  if (!s.running) return;
  s.running = false;
  eventSeq++;
  Event e{eventSeq, type, n, s.sessionNo, 0, 0, settings.rateVersion, 0, millis64(), unixTimeOrZero(), commandId};
  pushEvent(e);
  saveCheckpoint();
  Serial.printf("[session] tablet %u session #%lu %s\n", n, (unsigned long)s.sessionNo, type == EV_EXPIRE ? "expired" : "ended by admin");
  reportSoon();
}

void checkExpiry() {
  const uint64_t now = millis64();
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    if (stations[i].running && now >= stations[i].endMs) endSession(i, EV_EXPIRE, 0);
  }
  if (selStation && now >= selUntilMs) selStation = 0;
  if (anyRunning() && now - lastCheckpointMs >= CHECKPOINT_INTERVAL_S * 1000ULL) saveCheckpoint();
}

// ============================================================ LCD (20x4, I2C)
String lcdRows[LCD_ROWS];

// Custom LCD character 1: the peso sign (the HD44780 ROM has none). Slot 0 is
// avoided because a 0 byte would end the String.
const char LCD_PESO = 1;
const uint8_t PESO_GLYPH[8] = {0b11100, 0b11111, 0b10010, 0b11111, 0b11100, 0b10000, 0b10000, 0b00000};

void lcdRow(uint8_t row, String text) {
  if (!lcd) return;
  if (text.length() > LCD_COLS) text = text.substring(0, LCD_COLS);
  while (text.length() < LCD_COLS) text += ' ';
  if (text == lcdRows[row]) return;
  lcdRows[row] = text;
  lcd->setCursor(0, row);
  lcd->print(text);
}

// One tablet in 10 columns: ">2 12:03  " (> = next coins go here).
String tabletCell(uint8_t n) {
  const uint32_t r = remainingSeconds(n);
  char t[8];
  if (!r) snprintf(t, sizeof(t), " --  ");
  else if (r < 3600) snprintf(t, sizeof(t), "%02lu:%02lu", (unsigned long)(r / 60), (unsigned long)(r % 60));
  else snprintf(t, sizeof(t), "%luh%02lu", (unsigned long)(r / 3600), (unsigned long)((r % 3600) / 60));
  char cell[12];
  snprintf(cell, sizeof(cell), "%c%u %-5s  ", coinTarget() == n ? '>' : ' ', n, t);
  return String(cell).substring(0, 10);
}

void updateLcd() {
  static uint64_t last = 0;
  const uint64_t now = millis64();
  if (now - last < LCD_REFRESH_MS) return;
  last = now;

  if (setupMode) {
    lcdRow(0, "WIFI SETUP MODE");
    lcdRow(1, "AP:" + WiFi.softAPSSID());
    lcdRow(2, "Pass:" + apPassword);
    lcdRow(3, "Open 192.168.4.1");
    return;
  }
  lcdRow(0, selectionActive() ? "VeNdO  Insert: Tab " + String(selStation)
                              : soleTablet() ? String("VeNdO  INSERT COIN") : String("VeNdO  Ask staff"));
  if (pairingOpen) {
    lcdRow(1, String("PAIR CODE: ") + pairingCode);
    lcdRow(2, WiFi.localIP().toString());
    lcdRow(3, "Enter on the tablet");
    return;
  }
  lcdRow(1, tabletCell(1) + tabletCell(2));
  lcdRow(2, MAX_STATIONS >= 4 ? tabletCell(3) + tabletCell(4) : String());
  if (now < infoUntilMs) {
    lcdRow(3, WiFi.isConnected() ? WiFi.localIP().toString() + (pollState == CLOUD_OK ? " online" : "") : String("WiFi: not connected"));
  } else if (heldPulses) {
    lcdRow(3, String("Held: ") + LCD_PESO + String(heldPulses) + " ask staff");
  } else if (lastCoinPulses) {
    // One accepted pulse is one peso (1, 5, 10 and 20 peso coins).
    lcdRow(3, String("Last: ") + LCD_PESO + String(lastCoinPulses) + (lastCoinStation ? " Tab " + String(lastCoinStation) : String(" held")));
  } else {
    lcdRow(3, "Thank you!");
  }
}

bool initLcd() {
  // Configure I2C on D2/D5 BEFORE lcd.init(): the library calls Wire.begin()
  // without pins, which reuses these. (The ESP8266 default SCL is GPIO5 = D1,
  // our coin input, so this order matters.)
  Wire.begin(LCD_SDA_PIN, LCD_SCL_PIN);
  Wire.setClock(100000);
  // PCF8574 backpacks use 0x20-0x27, PCF8574A use 0x38-0x3F (same scan as the original sketch).
  uint8_t found = 0;
  for (uint8_t addr = 0x20; addr <= 0x3F; addr++) {
    if (addr > 0x27 && addr < 0x38) continue;
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      found = addr;
      break;
    }
    yield();
  }
  if (found) {
    lcd = new LiquidCrystal_I2C(found, LCD_COLS, LCD_ROWS);
    lcd->init();
    Wire.setClock(100000);
    lcd->backlight();
    lcd->createChar(1, (uint8_t *)PESO_GLYPH);
    lcd->clear();  // once, at initialization only
    Serial.printf("[lcd] found at 0x%02X\n", found);
    return true;
  }
  Serial.println("[lcd] no I2C display found (0x20-0x27, 0x38-0x3F) - check SDA=D2, SCL=D5, power, pull-ups");
  return false;
}

// ============================================================ tiny JSON readers for our own backend's replies
long jsonInt(const String &s, const char *key, int from = 0, long def = -1) {
  String k = String('"') + key + "\":";
  int i = s.indexOf(k, from);
  if (i < 0) return def;
  i += k.length();
  while (i < (int)s.length() && s[i] == ' ') i++;
  bool neg = false;
  if (i < (int)s.length() && s[i] == '-') {
    neg = true;
    i++;
  }
  if (i >= (int)s.length() || !isdigit((unsigned char)s[i])) return def;
  long v = 0;
  while (i < (int)s.length() && isdigit((unsigned char)s[i])) v = v * 10 + (s[i++] - '0');
  return neg ? -v : v;
}

String jsonStr(const String &s, const char *key, int from = 0) {
  String k = String('"') + key + "\":\"";
  int i = s.indexOf(k, from);
  if (i < 0) return String();
  i += k.length();
  int j = s.indexOf('"', i);
  return j < 0 ? String() : s.substring(i, j);
}

// Returns true if `seq` appears in the JSON integer array `key`.
bool jsonArrayHas(const String &s, const char *key, uint32_t seq) {
  String k = String('"') + key + "\":[";
  int i = s.indexOf(k);
  if (i < 0) return false;
  i += k.length();
  int end = s.indexOf(']', i);
  if (end < 0) return false;
  while (i < end) {
    while (i < end && !isdigit((unsigned char)s[i])) i++;
    uint32_t v = 0;
    bool any = false;
    while (i < end && isdigit((unsigned char)s[i])) {
      v = v * 10 + (s[i++] - '0');
      any = true;
    }
    if (any && v == seq) return true;
  }
  return false;
}

// ============================================================ HTTPS (one kept-alive, verified connection)
bool timeValid() { return time(nullptr) > 1700000000; }

// POSTs JSON to url; returns the HTTP status (negative on transport error).
// Poll, sync and the status upload share this connection, so the TLS handshake
// is paid once and each request takes ~0.1-0.5 s.
// Small TLS buffers (BearSSL then asks the server for 4 KB records with the
// max fragment length extension). Our server supports it, but only when the
// client sends the host name (SNI), which real connections do; the library's
// probe does not, so it is not used. If HTTPS keeps failing with small
// buffers, go back to full-size buffers for this boot.
bool tlsSmallBuffers = true;
uint8_t tlsFailures = 0;

void noteTlsResult(int code) {
  if (code > 0) {
    tlsFailures = 0;
    return;
  }
  if (!tlsSmallBuffers || !WiFi.isConnected() || code == -101) return;
  if (++tlsFailures >= 4) {
    tlsSmallBuffers = false;
    netClient.setBufferSizes(16384, TLS_TX_BUFFER);
    Serial.println("[net] HTTPS failing with small TLS buffers: using full size until restart");
  }
}

int httpsPost(const String &url, const String &body, const String &bearer, String &response) {
  if (ESP.getMaxFreeBlockSize() < TLS_MIN_FREE_BLOCK && !netClient.connected()) {
    Serial.printf("[net] low memory (largest block %u B), cloud call skipped\n", ESP.getMaxFreeBlockSize());
    response = String();
    return -101;
  }
  netClient.setX509Time(time(nullptr));
  if (!netHttp.begin(netClient, url)) return -100;
  netHttp.addHeader("Content-Type", "application/json");
  if (bearer.length()) netHttp.addHeader("Authorization", "Bearer " + bearer);
  const int code = netHttp.POST((uint8_t *)body.c_str(), body.length());
  response = code > 0 ? netHttp.getString() : String();  // read fully so the connection can be reused
  netHttp.end();  // keeps the socket open when the server allows keep-alive
  noteTlsResult(code);
  if (code < 0) {
    char err[80];
    netClient.getLastSSLError(err, sizeof(err));
    Serial.printf("[net] transport error %d (%s) %s\n", code, HTTPClient::errorToString(code).c_str(), err);
  }
  return code;
}

bool pulsesPending() {
  noInterrupts();
  const bool pending = isrInPulse || isrAcceptedPulses != committedPulses;
  interrupts();
  return pending;
}

bool cloudReady() {
  return !setupMode && WiFi.isConnected() && timeValid() && settings.cloudToken.length() && cloudState != CLOUD_UNAUTHORIZED;
}

// ============================================================ cloud enrollment + event sync
void cloudEnroll() {
  String body = String("{\"device_type\":\"controller\",\"enrollment_code\":\"") + sanitize(settings.enrollCode, 32) +
                "\",\"name\":\"" + sanitize(settings.deviceName, 60) + "\",\"hardware_id\":\"" + deviceId + "\"}";
  String resp;
  const int code = httpsPost(settings.apiBase + "/devices/enroll", body, String(), resp);
  if (code == 201) {
    String token = jsonStr(resp, "device_token");
    if (token.startsWith("vkd_")) {
      settings.cloudToken = token;
      settings.enrollCode = "";
      saveSettings();
      cloudState = CLOUD_OK;
      Serial.println("[cloud] enrolled");
      return;
    }
  }
  if (code == 403 || code == 422) {
    // Code invalid/expired/used: stop retrying; the operator must enter a new one.
    settings.enrollCode = "";
    saveSettings();
    cloudState = CLOUD_UNAUTHORIZED;
    Serial.printf("[cloud] enrollment rejected (%d)\n", code);
    return;
  }
  cloudState = CLOUD_ERROR;
}

const char *eventTypeName(uint8_t t) {
  switch (t) {
    case EV_CREDIT: return "credit";
    case EV_EXPIRE: return "expire";
    case EV_HELD: return "held";
    case EV_ASSIGN: return "assign";
    case EV_ADMIN_CREDIT: return "admin_credit";
    default: return "admin_end";
  }
}

String buildSyncBody(uint8_t &countOut) {
  countOut = min<uint8_t>(evCount, EVENTS_PER_SYNC);
  String b;
  b.reserve(760 + countOut * 230);  // what this batch needs, not the maximum
  b += "{\"protocol\":" + String(PROTOCOL_VERSION);
  b += ",\"boot_id\":\"" + bootId + "\"";
  b += ",\"uptime_ms\":" + u64str(millis64());
  b += ",\"fw_version\":\"" FW_VERSION "\"";
  b += ",\"config_version_applied\":" + String(settings.rateVersion);
  // Top-level session fields describe tablet 1 (compatible with protocol 1 readers).
  b += ",\"status\":{\"session\":\"" + String(remainingSeconds(1) ? "running" : "idle") + "\"";
  b += ",\"remaining_s\":" + String(remainingSeconds(1));
  b += ",\"seq\":" + String(eventSeq);
  b += ",\"session_no\":" + String(stations[1].sessionNo);
  b += ",\"seconds_per_pulse\":" + String(settings.secondsPerPulse);
  b += ",\"rate_version\":" + String(settings.rateVersion);
  b += ",\"wifi_rssi\":" + String(WiFi.RSSI());
  b += ",\"free_heap\":" + String(ESP.getFreeHeap());
  b += ",\"buffered_events\":" + String(evCount);
  b += ",\"dropped_events\":" + String(droppedEvents);
  b += ",\"held_pulses\":" + String(heldPulses);
  b += ",\"stations\":[";
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    const Station &s = stations[i];
    if (i > 1) b += ',';
    b += "{\"station\":" + String(i);
    b += ",\"session\":\"" + String(remainingSeconds(i) ? "running" : "idle") + "\"";
    b += ",\"remaining_s\":" + String(remainingSeconds(i));
    b += ",\"session_no\":" + String(s.sessionNo);
    b += ",\"paired\":" + String(s.pairKeyHex.length() ? "true" : "false");
    b += ",\"phone_last_poll_age_s\":" + String(s.lastPhonePollMs ? (long)((millis64() - s.lastPhonePollMs) / 1000) : -1L) + "}";
  }
  b += "]},\"events\":[";
  for (uint8_t i = 0; i < countOut; i++) {
    const Event &e = events[(evStart + i) % EVENT_BUFFER_SIZE];
    if (i) b += ',';
    b += "{\"seq\":" + String(e.seq);
    b += ",\"type\":\"" + String(eventTypeName(e.type)) + "\"";
    b += ",\"station\":" + String(e.station);
    b += ",\"session_no\":" + String(e.sessionNo);
    b += ",\"pulses\":" + String(e.pulses);
    b += ",\"seconds\":" + String(e.seconds);
    b += ",\"rate_version\":" + String(e.rateVersion);
    b += ",\"remaining_after\":" + String(e.remainingAfter);
    b += ",\"uptime_ms\":" + u64str(e.uptimeMs);
    b += ",\"unix_time\":" + String(e.unixTime);
    b += ",\"command_id\":" + String(e.commandId) + "}";
  }
  b += "]}";
  return b;
}

void removeAckedEvents(const String &resp) {
  // Keep any event that the server neither acknowledged nor rejected.
  // Compacted in place: the ESP8266 stack is only 4 KB.
  uint8_t kept = 0;
  for (uint8_t i = 0; i < evCount; i++) {
    const Event e = events[(evStart + i) % EVENT_BUFFER_SIZE];
    if (jsonArrayHas(resp, "acked_seqs", e.seq) || jsonArrayHas(resp, "rejected_seqs", e.seq)) continue;
    events[(evStart + kept) % EVENT_BUFFER_SIZE] = e;  // kept <= i, so no unread slot is overwritten
    kept++;
  }
  evCount = kept;
}

void applyCloudConfig(const String &resp) {
  const int cfgAt = resp.indexOf("\"config\":");
  if (cfgAt < 0) return;
  const long version = jsonInt(resp, "version", cfgAt);
  if (version <= 0 || (uint32_t)version <= settings.rateVersion) return;
  const long spp = jsonInt(resp, "seconds_per_pulse", cfgAt);
  const long sync = jsonInt(resp, "sync_interval_s", cfgAt);
  if (spp >= 10 && spp <= 3600) settings.secondsPerPulse = (uint32_t)spp;  // future coins only
  if (sync >= 5 && sync <= 300) settings.syncIntervalS = (uint32_t)sync;
  settings.rateVersion = (uint32_t)version;
  saveSettings();
  Serial.printf("[cloud] applied config v%ld: %lu s/pulse\n", version, (unsigned long)settings.secondsPerPulse);
}

void cloudSync() {
  uint8_t count = 0;
  String resp;
  const int code = httpsPost(settings.apiBase + "/controller/sync", buildSyncBody(count), settings.cloudToken, resp);
  if (code == 200) {
    removeAckedEvents(resp);
    applyCloudConfig(resp);
    cloudState = CLOUD_OK;
    cloudFailures = 0;
    lastCloudOkMs = millis64();
  } else if (code == 401) {
    cloudState = CLOUD_UNAUTHORIZED;  // revoked: keep events, stop until re-enrolled
    Serial.println("[cloud] credential rejected (revoked?) — re-enroll via setup portal");
  } else {
    cloudState = CLOUD_ERROR;
    cloudFailures++;
    Serial.printf("[cloud] sync failed: %d\n", code);
  }
}

void cloudLoop() {
  if (setupMode || !WiFi.isConnected()) return;
  if (settings.cloudToken.isEmpty() && settings.enrollCode.isEmpty()) {
    cloudState = CLOUD_DISABLED;
    return;
  }
  if (cloudState == CLOUD_UNAUTHORIZED && settings.enrollCode.isEmpty()) return;
  if (!timeValid()) {
    cloudState = CLOUD_WAIT_TIME;  // certificate validation needs the real date
    return;
  }
  const uint64_t now = millis64();
  if (now < nextSyncMs || pulsesPending()) return;
  if (!settings.enrollCode.isEmpty()) cloudEnroll();
  else cloudSync();
  // Exponential backoff on failure, capped; normal interval otherwise.
  uint32_t delayS = settings.syncIntervalS;
  if (cloudState == CLOUD_ERROR) delayS = min<uint32_t>(CLOUD_BACKOFF_MAX_S, settings.syncIntervalS << min<uint32_t>(cloudFailures, 5));
  // A backlog drains in small batches: the next one in a few seconds, not a full interval.
  else if (cloudState == CLOUD_OK && evCount > 0) delayS = MIN_SYNC_GAP_MS / 1000;
  nextSyncMs = millis64() + (uint64_t)delayS * 1000ULL;
}

// ============================================================ fast poll: attendant selection + dashboard commands
bool commandApplied(uint32_t id) {
  for (uint8_t i = 0; i < APPLIED_CMD_RING; i++) {
    if (appliedCmds[i] == id) return true;
  }
  return false;
}

void queueAck(uint32_t id, const char *result) {
  for (uint8_t i = 0; i < pendingAckCount; i++) {
    if (pendingAcks[i].id == id) return;
  }
  if (pendingAckCount < APPLIED_CMD_RING) pendingAcks[pendingAckCount++] = {id, result};
}

// Applies one command object from the poll reply, at most once per id.
void applyCommand(const String &obj) {
  const long id = jsonInt(obj, "id");
  if (id <= 0) return;
  if (commandApplied((uint32_t)id)) {
    queueAck((uint32_t)id, "ok");  // applied before; the ack was lost
    return;
  }
  const String type = jsonStr(obj, "type");
  const long n = jsonInt(obj, "station");
  const long seconds = jsonInt(obj, "seconds", 0, 0);
  const char *result = "ok";
  if (!validStation(n)) result = "bad_station";
  else if (type == "add_time") {
    if (seconds >= 60 && seconds <= (long)MAX_ADMIN_CREDIT_S) addTime(n, 0, seconds, EV_ADMIN_CREDIT, id);
    else result = "bad_seconds";
  } else if (type == "end_session") {
    if (stations[n].running) endSession(n, EV_ADMIN_END, id);
    else result = "not_running";
  } else if (type == "assign_held") {
    if (heldPulses) assignHeld(n, id);
    else result = "nothing_held";
  } else {
    result = "unknown_type";
  }
  appliedCmds[appliedCmdNext] = (uint32_t)id;
  appliedCmdNext = (appliedCmdNext + 1) % APPLIED_CMD_RING;
  saveCheckpoint();  // remember the id before the ack can reach the dashboard
  queueAck((uint32_t)id, result);
  Serial.printf("[cmd] #%ld %s tablet %ld: %s\n", id, type.c_str(), n, result);
}

void controllerPoll() {
  String b;
  b.reserve(220 + pendingAckCount * 40);
  b += "{\"boot_id\":\"" + bootId + "\"";
  b += ",\"selected\":" + String(selectionActive() ? selStation : 0);
  b += ",\"selected_ttl_s\":" + String(selectionTtlS());
  b += ",\"held_pulses\":" + String(heldPulses);
  b += ",\"acks\":[";
  const uint8_t sentAcks = pendingAckCount;
  for (uint8_t i = 0; i < sentAcks; i++) {
    if (i) b += ',';
    b += "{\"id\":" + String(pendingAcks[i].id) + ",\"result\":\"" + pendingAcks[i].result + "\"}";
  }
  b += "]}";
  String resp;
  const int code = httpsPost(settings.apiBase + "/controller/poll", b, settings.cloudToken, resp);
  if (code != 200) {
    pollState = code == 401 ? CLOUD_UNAUTHORIZED : CLOUD_ERROR;
    pollFailures++;
    return;
  }
  pollState = CLOUD_OK;
  pollFailures = 0;
  // Acks delivered: drop the ones we sent (new ones may have been queued meanwhile).
  for (uint8_t i = sentAcks; i < pendingAckCount; i++) pendingAcks[i - sentAcks] = pendingAcks[i];
  pendingAckCount -= sentAcks;

  // Attendant selection: apply only a newer version (a local button choice stays until then).
  const int selAt = resp.indexOf("\"selection\":");
  if (selAt >= 0) {
    const long version = jsonInt(resp, "version", selAt, 0);
    if (version > 0 && (uint32_t)version != selVersionApplied) {
      selVersionApplied = (uint32_t)version;
      setSelection((uint8_t)jsonInt(resp, "station", selAt, 0), (uint32_t)jsonInt(resp, "ttl_s", selAt, 0));
    }
  }
  // Commands: an array of flat objects.
  int at = resp.indexOf("\"commands\":[");
  if (at < 0) return;
  const int end = resp.indexOf(']', at);
  while (end > 0) {
    const int open = resp.indexOf('{', at);
    if (open < 0 || open > end) break;
    const int close = resp.indexOf('}', open);
    if (close < 0 || close > end) break;
    applyCommand(resp.substring(open, close + 1));
    at = close + 1;
  }
}

void pollLoop() {
  if (!cloudReady()) {
    pollState = settings.cloudToken.length() ? CLOUD_WAIT_TIME : CLOUD_DISABLED;
    return;
  }
  const uint64_t now = millis64();
  if (now < nextPollMs || pulsesPending()) return;
  controllerPoll();
  const uint64_t backoff = pollFailures ? min<uint64_t>(POLL_BACKOFF_MAX_MS, (uint64_t)POLL_INTERVAL_MS << min<uint32_t>(pollFailures, 4)) : POLL_INTERVAL_MS;
  nextPollMs = millis64() + backoff;
}

// ============================================================ status.php upload (existing database, tablet 1)
bool statusUpload() {
  const uint32_t started = millis();
  statusSequence++;
  char body[300];
  snprintf(body, sizeof(body),
           "{\"device_id\":\"%s\",\"boot_id\":\"%s\",\"sequence\":%lu,\"remaining_seconds\":%lu,\"last_pulses\":%lu}",
           sanitize(settings.statusDeviceId, 64).c_str(), statusBootId, (unsigned long)statusSequence,
           (unsigned long)remainingSeconds(1), (unsigned long)stations[1].lastPulses);
  String resp;
  const int code = httpsPost(settings.statusUrl, String(body), settings.statusToken, resp);
  const bool ok = code == 200 && resp.indexOf("\"saved\"") >= 0;
  if (code > 0) {
    Serial.printf("[status] upload #%lu: HTTP %d in %lu ms, heap %u/%u B%s\n", (unsigned long)statusSequence, code,
                  (unsigned long)(millis() - started), ESP.getFreeHeap(), ESP.getMaxFreeBlockSize(), ok ? "" : " (not saved)");
    if (code == 401 || code == 403) {
      statusState = CLOUD_UNAUTHORIZED;
      Serial.printf("[status] server says: %s\n", resp.substring(0, 160).c_str());  // never contains our token
    }
  }
  return ok;
}

void statusLoop() {
  if (setupMode || settings.statusToken.isEmpty()) {
    statusState = CLOUD_DISABLED;
    return;
  }
  if (!WiFi.isConnected()) return;
  if (!timeValid()) {
    statusState = CLOUD_WAIT_TIME;  // certificate validation needs the real date
    return;
  }
  const uint64_t since = millis64() - lastStatusUploadMs;
  const uint64_t periodic = remainingSeconds(1) ? STATUS_RUNNING_INTERVAL_MS : STATUS_IDLE_INTERVAL_MS;
  // A rejected token will not fix itself: retry slowly (60 s) instead of every 5 s.
  const uint64_t minGap = statusState == CLOUD_UNAUTHORIZED ? 60000ULL : statusLastFailed ? STATUS_RETRY_MS : STATUS_MIN_GAP_MS;
  const bool due = (statusUploadNeeded && since >= minGap) || since >= periodic;
  if (!due || pulsesPending()) return;  // wait until a coin's pulse train is complete
  const bool ok = statusUpload();
  lastStatusUploadMs = millis64();
  statusLastFailed = !ok;
  if (ok) {
    statusUploadNeeded = false;
    statusState = CLOUD_OK;
  } else if (statusState != CLOUD_UNAUTHORIZED) {
    statusState = CLOUD_ERROR;
  }
}

// ============================================================ local HTTP API (tablets, protocol 2)
const char *cloudStateName(CloudState state = cloudState) {
  switch (state) {
    case CLOUD_OK: return "ok";
    case CLOUD_WAIT_TIME: return "waiting_for_time";
    case CLOUD_ERROR: return "error";
    case CLOUD_UNAUTHORIZED: return "unauthorized";
    default: return "disabled";
  }
}

void sendJson(int code, const String &body) {
  server.sendHeader("Cache-Control", "no-store");
  server.send(code, "application/json", body);
}

void sendError(int code, const char *err) {
  sendJson(code, String("{\"ok\":false,\"error\":\"") + err + "\"}");
}

// Tablet number from ?station=N, or 0 (and an error response) when invalid.
uint8_t stationArg() {
  const long n = server.arg("station").toInt();
  if (!validStation(n)) {
    sendError(400, "bad_station");
    return 0;
  }
  return (uint8_t)n;
}

// GET /api/v1/info — unauthenticated, contains no secrets and cannot change anything.
void handleInfo() {
  String b = "{\"ok\":true,\"protocol\":" + String(PROTOCOL_VERSION) + ",\"device_id\":\"" + deviceId +
             "\",\"fw_version\":\"" FW_VERSION "\",\"stations\":" + String(MAX_STATIONS) + ",\"paired\":[";
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
    if (i > 1) b += ',';
    b += stations[i].pairKeyHex.length() ? "true" : "false";
  }
  b += "],\"pairing_open\":" + String(pairingOpen ? "true" : "false") + "}";
  sendJson(200, b);
}

// GET /api/v1/status?station=N&nonce=<16-64 hex>
// Signed with tablet N's key: X-VK-Signature = HMAC-SHA256(key, "VK2|status|N|" + nonce + "|" + body)
void handleStatus() {
  const uint8_t n = stationArg();
  if (!n) return;
  Station &s = stations[n];
  if (s.pairKeyHex.isEmpty()) return sendError(403, "not_paired");
  const String nonce = server.arg("nonce");
  if (!isHex(nonce, 16, 64)) return sendError(400, "bad_nonce");
  s.lastPhonePollMs = millis64();
  const uint32_t rem = remainingSeconds(n);
  String b;
  b.reserve(520);
  b += "{\"ok\":true,\"protocol\":" + String(PROTOCOL_VERSION);
  b += ",\"device_id\":\"" + deviceId + "\"";
  b += ",\"boot_id\":\"" + bootId + "\"";
  b += ",\"station\":" + String(n);
  b += ",\"uptime_ms\":" + u64str(millis64());
  b += ",\"seq\":" + String(eventSeq);
  b += ",\"session_no\":" + String(s.sessionNo);
  b += ",\"session\":\"" + String(rem ? "running" : "idle") + "\"";
  b += ",\"remaining_s\":" + String(rem);
  b += ",\"seconds_per_pulse\":" + String(settings.secondsPerPulse);
  b += ",\"rate_version\":" + String(settings.rateVersion);
  b += ",\"last_added_s\":" + String(s.lastAddedS);
  b += ",\"last_pulses\":" + String(s.lastPulses);
  b += ",\"selected_station\":" + String(coinTarget());
  b += ",\"selected_ttl_s\":" + String(selectionTtlS());
  b += ",\"held_pulses\":" + String(heldPulses);
  b += ",\"charge_relay\":" + String(chargeRelayOn() ? "true" : "false");
  b += ",\"resumed\":" + String(resumedFromCheckpoint ? "true" : "false");
  b += ",\"cloud\":\"" + String(cloudStateName(pollState)) + "\"";
  b += ",\"status_upload\":\"" + String(cloudStateName(statusState)) + "\"";
  b += ",\"nonce\":\"" + nonce + "\"}";
  server.sendHeader("X-VK-Signature", hmacHex(s.pairKeyHex, "VK2|status|" + String(n) + "|" + nonce + "|" + b));
  sendJson(200, b);
}

// POST /api/v1/pair  (form: code, phone_id, station) — only while the physical pairing window is open.
void handlePair() {
  if (!pairingOpen) return sendError(403, "pairing_closed");
  if (pairingAttempts >= PAIRING_MAX_ATTEMPTS) return sendError(429, "too_many_attempts");
  pairingAttempts++;
  const String code = server.arg("code");
  if (!constantTimeEquals(code, String(pairingCode))) {
    if (pairingAttempts >= PAIRING_MAX_ATTEMPTS) pairingOpen = false;
    return sendError(403, "wrong_code");
  }
  const uint8_t n = stationArg();
  if (!n) return;
  Station &s = stations[n];
  const bool replaced = s.pairKeyHex.length() > 0;
  s.pairKeyHex = randomHex(32);
  s.pairedPhoneId = sanitize(server.arg("phone_id"), 40);
  s.lastCmdCounter = 0;
  saveSettings();
  pairingOpen = false;
  sendJson(200, "{\"ok\":true,\"device_id\":\"" + deviceId + "\",\"boot_id\":\"" + bootId + "\",\"station\":" + String(n) +
                    ",\"key\":\"" + s.pairKeyHex + "\"}");
  Serial.printf("[pair] tablet %u paired%s\n", n, replaced ? " (previous pairing replaced)" : "");
}

// Authenticated tablet command: mac = HMAC(key_N, "VK2|cmd|<name>|N|<boot_id>|<ctr>"),
// ctr strictly increasing per tablet within this boot (prevents replay).
uint8_t verifyCommand(const char *name) {
  const uint8_t n = stationArg();
  if (!n) return 0;
  Station &s = stations[n];
  if (s.pairKeyHex.isEmpty()) {
    sendError(403, "not_paired");
    return 0;
  }
  const String boot = server.arg("boot_id");
  const uint32_t ctr = strtoul(server.arg("ctr").c_str(), nullptr, 10);
  const String mac = server.arg("mac");
  if (boot != bootId || ctr <= s.lastCmdCounter) {
    sendError(409, "stale_command");
    return 0;
  }
  const String expected = hmacHex(s.pairKeyHex, String("VK2|cmd|") + name + "|" + String(n) + "|" + boot + "|" + String(ctr));
  if (!constantTimeEquals(mac, expected)) {
    sendError(403, "bad_mac");
    return 0;
  }
  s.lastCmdCounter = ctr;
  return n;
}

void handleEndSession() {
  const uint8_t n = verifyCommand("end_session");
  if (!n) return;
  endSession(n, EV_ADMIN_END, 0);
  sendJson(200, "{\"ok\":true}");
}

// POST /api/v1/select — a player tapped "Insert coin" on tablet N: the next
// coins go to it. First come, first served: while another tablet's claim (or
// the attendant's selection) is active the answer is 409 busy.
void handleSelect() {
  const uint8_t n = verifyCommand("select");
  if (!n) return;
  if (selectionActive() && selStation != n) {
    sendJson(409, "{\"ok\":false,\"error\":\"busy\",\"selected_station\":" + String(selStation) +
                      ",\"ttl_s\":" + String(selectionTtlS()) + "}");
    return;
  }
  setSelection(n, TABLET_CLAIM_TTL_S);
  reportSoon();  // the dashboard shows who is inserting coins
  sendJson(200, "{\"ok\":true,\"station\":" + String(n) + ",\"ttl_s\":" + String(selectionTtlS()) + "}");
}

// POST /api/v1/charge/on | /api/v1/charge/off: tablet N's battery is low /
// charged again. The relay is on while any paired tablet wants it; the request
// is saved, so a restart keeps charging a flat tablet.
void handleCharge(bool on) {
  const uint8_t n = verifyCommand(on ? "charge_on" : "charge_off");
  if (!n) return;
  if (stations[n].chargeWanted != on) {
    stations[n].chargeWanted = on;
    saveSettings();
    Serial.printf("[relay] tablet %u %s charging\n", n, on ? "requests" : "no longer needs");
  }
  applyChargeRelay();
  sendJson(200, "{\"ok\":true,\"relay\":" + String(chargeRelayOn() ? "true" : "false") + "}");
}

void handleUnpair() {
  const uint8_t n = verifyCommand("unpair");
  if (!n) return;
  sendJson(200, "{\"ok\":true}");
  stations[n].pairKeyHex = "";
  stations[n].pairedPhoneId = "";
  stations[n].chargeWanted = false;
  saveSettings();
  applyChargeRelay();
}

// ============================================================ setup portal (Wi-Fi + cloud enrollment)
String htmlEscape(const String &s) {
  String o;
  for (size_t i = 0; i < s.length(); i++) {
    char c = s[i];
    if (c == '<') o += "&lt;";
    else if (c == '>') o += "&gt;";
    else if (c == '&') o += "&amp;";
    else if (c == '"') o += "&quot;";
    else o += c;
  }
  return o;
}

void handleSetupPage() {
  String p;
  p.reserve(2600);
  p += F("<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><title>Vendo coin controller setup</title>"
         "<style>body{font-family:sans-serif;max-width:480px;margin:auto;padding:16px}label{display:block;margin:12px 0}"
         "input{width:100%;padding:10px;font-size:16px;box-sizing:border-box}button{padding:12px 20px;font-size:16px}</style>"
         "<h1>Coin controller setup</h1>");
  p += "<p>Device ID: <b>" + deviceId + "</b> · firmware " FW_VERSION "</p>";
  p += F("<form method=post action=/save>"
         "<label>Wi-Fi network name (SSID)<input name=ssid required maxlength=32 value=\"");
  p += htmlEscape(settings.wifiSsid);
  p += F("\"></label><label>Wi-Fi password<input name=pass type=password maxlength=64 placeholder='(unchanged if empty)'></label>"
         "<label>Controller name<input name=name maxlength=60 value=\"");
  p += htmlEscape(settings.deviceName);
  p += F("\"></label><label>Cloud enrollment code (from the dashboard; needed to choose tablets from the dashboard)<input name=enroll maxlength=16 placeholder='XXXXX-XXXXX'></label>"
         "<label>API base URL<input name=api maxlength=120 value=\"");
  p += htmlEscape(settings.apiBase);
  p += F("\"></label><p>Cloud: ");
  p += settings.cloudToken.length() ? "enrolled" : "not enrolled";
  p += F("</p><h2>Upload to existing status.php (tablet 1)</h2><label>Status URL<input name=status_url maxlength=120 value=\"");
  p += htmlEscape(settings.statusUrl);
  p += F("\"></label><label>Status device ID<input name=status_device maxlength=64 value=\"");
  p += htmlEscape(settings.statusDeviceId);
  p += F("\"></label><label>Status upload token (64 characters)<input name=status_token type=password maxlength=128 "
         "autocomplete=off placeholder='");
  p += settings.statusToken.length() ? F("(saved; leave empty to keep)") : F("(not set: upload disabled)");
  p += F("'></label><label><input type=checkbox name=status_clear value=1 style='width:auto'> Remove the saved upload token</label>"
         "<button>Save and restart</button></form>"
         "<p><small>Saving does not change paid time. Tablet pairing is separate: hold the FLASH button 3 s in normal mode.</small></p>");
  server.send(200, "text/html", p);
}

void handleSetupSave() {
  const String ssid = server.arg("ssid");
  if (ssid.isEmpty() || ssid.length() > 32 || ssid.indexOf('\n') >= 0) {
    server.send(400, "text/plain", "Invalid SSID");
    return;
  }
  settings.wifiSsid = ssid;
  const String pass = server.arg("pass");
  if (pass.length() && pass.indexOf('\n') < 0 && pass.length() <= 64) settings.wifiPass = pass;
  const String name = sanitize(server.arg("name"), 60);
  if (name.length()) settings.deviceName = name;
  const String enroll = sanitize(server.arg("enroll"), 16);
  if (enroll.length()) {
    settings.enrollCode = enroll;
    settings.cloudToken = "";  // re-enrollment replaces the old credential
  }
  const String api = sanitize(server.arg("api"), 120);
  if (api.startsWith("https://")) settings.apiBase = api;  // HTTPS only
  const String statusUrl = sanitize(server.arg("status_url"), 120);
  if (statusUrl.startsWith("https://")) settings.statusUrl = statusUrl;  // HTTPS only
  const String statusDevice = sanitize(server.arg("status_device"), 64);
  if (statusDevice.length()) settings.statusDeviceId = statusDevice;
  const String statusToken = sanitize(server.arg("status_token"), 128);
  if (statusToken.length() >= 16) settings.statusToken = statusToken;
  if (server.arg("status_clear") == "1") settings.statusToken = "";
  saveSettings();
  LittleFS.remove(FORCE_SETUP_FILE);
  server.send(200, "text/html", "<p>Saved. Restarting&hellip; Reconnect your phone to your normal Wi-Fi.</p>");
  delay(500);
  ESP.restart();
}

// ============================================================ FLASH button
// short press  → next coins go to the next tablet (offline fallback; inside the locked box)
// hold 1-3 s   → show IP / device id on the LCD for 10 s
// hold 3 s     → open the tablet pairing window
// hold 10 s    → restart into Wi-Fi setup
void cycleSelection() {
  const uint8_t next = selectionActive() ? selStation + 1 : 1;
  setSelection(next > MAX_STATIONS ? 0 : next, SELECTION_TTL_S);
}

void buttonLoop() {
  static uint64_t downSince = 0;
  static bool wasDown = false;
  static bool actedPair = false;
  const bool down = digitalRead(BUTTON_PIN) == LOW;
  const uint64_t now = millis64();
  if (down && !wasDown) {
    downSince = now;
    actedPair = false;
  }
  if (down && !setupMode) {
    const uint64_t held = now - downSince;
    if (held >= BUTTON_SETUP_HOLD_MS) {
      File f = LittleFS.open(FORCE_SETUP_FILE, "w");
      if (f) f.close();
      saveCheckpoint();
      lcdRow(2, "Restarting into");
      lcdRow(3, "Wi-Fi setup...");
      delay(300);
      ESP.restart();
    } else if (held >= BUTTON_PAIR_HOLD_MS && !actedPair) {
      actedPair = true;
      openPairingWindow();
    }
  }
  if (!down && wasDown && !setupMode) {
    const uint64_t held = now - downSince;
    if (held >= 50 && held < BUTTON_INFO_MAX_MS) cycleSelection();
    else if (held >= BUTTON_INFO_HOLD_MS && held < BUTTON_PAIR_HOLD_MS) infoUntilMs = now + 10000;
  }
  wasDown = down;
  if (pairingOpen && now >= pairingUntilMs) pairingOpen = false;
}

// ============================================================ setup / loop
void startWifi() {
  WiFi.persistent(false);  // we store credentials ourselves; avoid SDK flash writes
  const bool forceSetup = LittleFS.exists(FORCE_SETUP_FILE);
  if (settings.wifiSsid.isEmpty() || forceSetup) {
    setupMode = true;
    apPassword = String(10000000UL + (ESP.random() % 90000000UL));  // 8 digits, shown on LCD
    WiFi.mode(WIFI_AP);
    WiFi.softAP(("VendoCoin-" + deviceId.substring(3)).c_str(), apPassword.c_str());
    server.on("/", HTTP_GET, handleSetupPage);
    server.on("/save", HTTP_POST, handleSetupSave);
    Serial.printf("[wifi] setup portal: SSID %s password %s at http://192.168.4.1\n", WiFi.softAPSSID().c_str(), apPassword.c_str());
  } else {
    WiFi.mode(WIFI_STA);
    WiFi.setSleepMode(WIFI_NONE_SLEEP);  // keep the local API responsive
    WiFi.hostname(("vendo-coin-" + deviceId.substring(3)).c_str());
    WiFi.setAutoReconnect(true);
    WiFi.begin(settings.wifiSsid.c_str(), settings.wifiPass.c_str());
    configTime(0, 0, "pool.ntp.org", "time.google.com", "time.cloudflare.com");
  }
  server.on("/api/v1/info", HTTP_GET, handleInfo);
  server.on("/api/v1/status", HTTP_GET, handleStatus);
  server.on("/api/v1/pair", HTTP_POST, handlePair);
  server.on("/api/v1/session/end", HTTP_POST, handleEndSession);
  server.on("/api/v1/unpair", HTTP_POST, handleUnpair);
  server.on("/api/v1/select", HTTP_POST, handleSelect);
  server.on("/api/v1/charge/on", HTTP_POST, []() { handleCharge(true); });
  server.on("/api/v1/charge/off", HTTP_POST, []() { handleCharge(false); });
  server.onNotFound([]() { sendError(404, "not_found"); });
  server.begin();
}

void setup() {
  Serial.begin(115200);
  Serial.println();
  Serial.println("Vendo coin controller " FW_VERSION);

  deviceId = "vk-" + String(ESP.getChipId(), HEX);
  bootId = randomHex(4);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  digitalWrite(CHARGE_RELAY_PIN, CHARGE_RELAY_ACTIVE_LOW ? HIGH : LOW);  // off until settings are loaded
  pinMode(CHARGE_RELAY_PIN, OUTPUT);

  if (!LittleFS.begin()) {
    Serial.println("[fs] mount failed, formatting");
    LittleFS.format();
    LittleFS.begin();
  }
  loadSettings();
  restoreCheckpoint();
  applyChargeRelay();

  initLcd();  // I2C on D2/D5 must be set up before the coin pin interrupt

  pinMode(COIN_PIN, COIN_USE_INTERNAL_PULLUP ? INPUT_PULLUP : INPUT);
  attachInterrupt(digitalPinToInterrupt(COIN_PIN), onCoinEdge, CHANGE);

  trustAnchors = new BearSSL::X509List(TRUST_ANCHORS_PEM);
  snprintf(statusBootId, sizeof(statusBootId), "%06lx-%08lx-%08lx", (unsigned long)ESP.getChipId(),
           (unsigned long)ESP.random(), (unsigned long)ESP.random());
  netClient.setTrustAnchors(trustAnchors);  // verified HTTPS, never setInsecure()
  netClient.setBufferSizes(TLS_RX_BUFFER, TLS_TX_BUFFER);  // see noteTlsResult
  netClient.setSession(&netSession);
  netClient.setTimeout(HTTP_TIMEOUT_MS);
  netHttp.setReuse(true);
  netHttp.setTimeout(HTTP_TIMEOUT_MS);
  startWifi();
  nextSyncMs = millis64() + 5000;
  nextPollMs = millis64() + 3000;
  uint8_t paired = 0;
  for (uint8_t i = 1; i <= MAX_STATIONS; i++) paired += stations[i].pairKeyHex.length() ? 1 : 0;
  Serial.printf("[boot] device %s boot %s rate %lu s/pulse, %u tablet(s) paired, %lu peso(s) held%s\n", deviceId.c_str(),
                bootId.c_str(), (unsigned long)settings.secondsPerPulse, paired, (unsigned long)heldPulses,
                resumedFromCheckpoint ? " (sessions restored)" : "");
}

void logWifiChanges() {
  static bool was = false;
  const bool now = WiFi.isConnected();
  if (now == was || setupMode) return;
  was = now;
  if (now) {
    Serial.printf("[wifi] connected to %s, IP %s (use this IP to pair the tablets)\n", WiFi.SSID().c_str(),
                  WiFi.localIP().toString().c_str());
  } else {
    Serial.println("[wifi] disconnected; coins and the timers keep working");
  }
}

// Opens the 2-minute tablet pairing window with a fresh 6-digit code.
// Triggered by holding FLASH 3 s or by the USB serial command "pair".
void openPairingWindow() {
  snprintf(pairingCode, sizeof(pairingCode), "%06lu", (unsigned long)(ESP.random() % 1000000UL));
  pairingOpen = true;
  pairingAttempts = 0;
  pairingUntilMs = millis64() + PAIRING_WINDOW_MS;
  // Also on serial (USB = physical access, like the button) in case the LCD is unreadable.
  Serial.printf("[pair] pairing window open for 120 s: code %s, IP %s\n", pairingCode, WiFi.localIP().toString().c_str());
}

// USB serial commands (physical access, like the FLASH button or reflashing):
//   pair                      → open the tablet pairing window and print the code
//   status                    → print every tablet's time, selection and held coins
//   select=N                  → next coins go to tablet N (0 = hold)
//   enroll=XXXXX-XXXXX        → enroll with a one-time coin box code from the dashboard
//   relay=on | off | auto     → test the D6 charger relay (not saved; auto = tablets decide)
//   status_token=<token>      status_device_id=<id>      status_url=https://...
// Values are saved to flash; the token is never printed back.
void serialConfigLoop() {
  static String line;
  while (Serial.available()) {
    const char c = (char)Serial.read();
    if (c == '\r') continue;
    if (c != '\n') {
      if (line.length() < 200) line += c;
      continue;
    }
    const int eq = line.indexOf('=');
    const String key = eq > 0 ? line.substring(0, eq) : line;
    const String value = eq > 0 ? sanitize(line.substring(eq + 1), 128) : String();
    line = "";
    bool changed = false;
    if (key == "pair") {
      openPairingWindow();
    } else if (key == "status") {
      Serial.printf("[status] heap free %u B, largest block %u B, buffered events %u\n", ESP.getFreeHeap(),
                    ESP.getMaxFreeBlockSize(), evCount);
      Serial.printf("[status] IP %s, poll %s, sync %s, upload %s, next coins -> %s (%lu s), held %lu peso(s)\n",
                    WiFi.localIP().toString().c_str(), cloudStateName(pollState), cloudStateName(cloudState),
                    cloudStateName(statusState), coinTarget() ? ("tablet " + String(coinTarget()) + (selectionActive() ? "" : " (only paired tablet)")).c_str() : "held",
                    (unsigned long)selectionTtlS(), (unsigned long)heldPulses);
      for (uint8_t i = 1; i <= MAX_STATIONS; i++) {
        Serial.printf("[status] tablet %u: %s remaining %lu s, session %lu, last %lu pulse(s), paired %s%s\n", i,
                      remainingSeconds(i) ? "running" : "idle", (unsigned long)remainingSeconds(i),
                      (unsigned long)stations[i].sessionNo, (unsigned long)stations[i].lastPulses,
                      stations[i].pairKeyHex.length() ? "yes" : "no", stations[i].chargeWanted ? ", wants charging" : "");
      }
      Serial.printf("[status] charger relay (D6) %s%s\n", chargeRelayOn() ? "ON" : "OFF",
                    relayOverride >= 0 ? " (serial test)" : "");
    } else if (key == "select") {
      setSelection(value.toInt(), SELECTION_TTL_S);
    } else if (key == "relay" && (value == "on" || value == "off" || value == "auto")) {
      relayOverride = value == "auto" ? -1 : (value == "on" ? 1 : 0);
      applyChargeRelay();
    } else if (key == "enroll" && value.length() >= 10 && value.length() <= 16) {
      // Same as the setup portal's enrollment field: a one-time coin box code from the dashboard.
      settings.enrollCode = value;
      settings.cloudToken = "";  // re-enrollment replaces the old credential
      saveSettings();
      cloudState = CLOUD_DISABLED;
      nextSyncMs = 0;
      Serial.println("[config] enrollment code saved; enrolling on the next cloud sync");
    } else if (key == "status_token" && value.length() >= 16) {
      settings.statusToken = value;
      changed = true;
    } else if (key == "status_device_id" && value.length()) {
      settings.statusDeviceId = value;
      changed = true;
    } else if (key == "status_url" && value.startsWith("https://")) {
      settings.statusUrl = value;
      changed = true;
    } else if (key.length()) {
      Serial.println("[config] unknown or invalid setting");
    }
    if (changed) {
      saveSettings();
      statusState = CLOUD_DISABLED;  // clear "unauthorized" and upload right away
      statusLastFailed = false;
      statusUploadNeeded = true;
      lastStatusUploadMs = 0;
      Serial.printf("[config] %s updated and saved\n", key.c_str());
    }
  }
}

void loop() {
  millis64();  // keep the 64-bit clock's wrap tracking current
  logWifiChanges();
  serialConfigLoop();
  processPulses();
  checkExpiry();
  buttonLoop();
  server.handleClient();
  updateLcd();
  pollLoop();    // attendant selection + dashboard commands (~2 s, kept-alive TLS)
  statusLoop();  // existing status.php database (tablet 1)
  cloudLoop();   // event sync to the dashboard
  yield();
}
