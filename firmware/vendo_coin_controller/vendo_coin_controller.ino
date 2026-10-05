/*
  Vendo Kiosk — ESP8266 coin controller
  =====================================
  Board:   NodeMCU 1.0 (ESP-12E) or LOLIN(WEMOS) D1 mini, ESP8266 Arduino core 3.1.x
  Libs:    LiquidCrystal_I2C 1.1.x (Frank de Brabander). No JSON library needed.

  This controller is the AUTHORITY for paid time:
   - counts coin pulses (IRAM interrupt), groups them into one credit per coin,
     adds seconds_per_pulse x pulses to the running session;
   - serves an authenticated local HTTP API so the paired kiosk phone can read
     the remaining time (responses are HMAC-signed over a phone nonce);
   - reports coin events to the cloud over verified HTTPS (outbound only).
  Nothing on the network can add time; only accepted coin pulses can.

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

static const char *SETTINGS_FILE = "/settings.txt";
static const char *SESSION_FILE = "/session.txt";
static const char *FORCE_SETUP_FILE = "/force_setup";

// ============================================================ runtime state
LiquidCrystal_I2C *lcd = nullptr;
ESP8266WebServer server(LOCAL_HTTP_PORT);
BearSSL::X509List *trustAnchors = nullptr;
BearSSL::Session tlsSession;

String deviceId;  // "vk-" + chip id
String bootId;    // random per boot: lets the phone and cloud detect restarts

bool setupMode = false;
String apPassword;

// Session (authoritative)
bool sessionRunning = false;
uint64_t sessionEndMs = 0;
uint32_t sessionNo = 0;
uint32_t eventSeq = 0;  // credit-event sequence number for this boot
uint32_t lastAddedS = 0;
uint32_t lastPulses = 0;
uint32_t committedPulses = 0;
uint64_t lastCheckpointMs = 0;
bool resumedFromCheckpoint = false;

// Cloud event buffer (bounded ring)
Event events[EVENT_BUFFER_SIZE];
uint8_t evStart = 0, evCount = 0;
uint32_t droppedEvents = 0;

// Cloud status
CloudState cloudState = CLOUD_DISABLED;

// status.php upload state
BearSSL::WiFiClientSecure statusClient;  // kept open between uploads (keep-alive)
HTTPClient statusHttp;
BearSSL::Session statusSession;          // cached TLS session for fast reconnects
char statusBootId[40];                   // same format as the original sketch
uint32_t statusSequence = 0;             // counts uploads (as the original sketch did)
bool statusUploadNeeded = true;
bool statusLastFailed = false;
uint64_t lastStatusUploadMs = 0;
CloudState statusState = CLOUD_DISABLED;
uint64_t nextSyncMs = 0;
uint32_t cloudFailures = 0;
int16_t tlsRxBuffer = 0;  // 0 = not probed yet
uint64_t lastCloudOkMs = 0;

// Pairing / admin
bool pairingOpen = false;
uint64_t pairingUntilMs = 0;
uint8_t pairingAttempts = 0;
char pairingCode[7] = {0};
uint32_t lastCmdCounter = 0;
uint64_t lastPhonePollMs = 0;
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

String hmacHex(const String &message) {
  uint8_t key[32];
  if (!hexToBytes(settings.pairKeyHex, key, sizeof(key))) return String();
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
  f.printf("pair_key=%s\n", settings.pairKeyHex.c_str());
  f.printf("paired_phone=%s\n", settings.pairedPhoneId.c_str());
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
    else if (k == "pair_key") settings.pairKeyHex = v;
    else if (k == "paired_phone") settings.pairedPhoneId = v;
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

// ============================================================ session (authoritative time)
uint32_t remainingSeconds() {
  if (!sessionRunning) return 0;
  const uint64_t now = millis64();
  if (now >= sessionEndMs) return 0;
  return (uint32_t)((sessionEndMs - now + 999) / 1000);
}

void saveCheckpoint() {
#if RESUME_AFTER_RESTART
  File f = LittleFS.open(SESSION_FILE, "w");
  if (!f) return;
  f.printf("remaining=%lu\nsession_no=%lu\n", (unsigned long)remainingSeconds(), (unsigned long)sessionNo);
  f.close();
  lastCheckpointMs = millis64();
#endif
}

void restoreCheckpoint() {
#if RESUME_AFTER_RESTART
  File f = LittleFS.open(SESSION_FILE, "r");
  if (!f) return;
  uint32_t remaining = 0, no = 0;
  while (f.available()) {
    String line = f.readStringUntil('\n');
    if (line.startsWith("remaining=")) remaining = line.substring(10).toInt();
    else if (line.startsWith("session_no=")) no = line.substring(11).toInt();
  }
  f.close();
  if (remaining > 0 && remaining <= MAX_SESSION_SECONDS) {
    sessionRunning = true;
    sessionNo = no;
    sessionEndMs = millis64() + (uint64_t)remaining * 1000ULL;
    resumedFromCheckpoint = true;
  }
#endif
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

void creditPulses(uint32_t pulses) {
  const uint32_t add = pulses * settings.secondsPerPulse;
  const uint64_t now = millis64();
  if (!sessionRunning || sessionEndMs <= now) {
    sessionRunning = true;
    sessionNo++;
    sessionEndMs = now;
  }
  sessionEndMs += (uint64_t)add * 1000ULL;  // additional coins extend the session
  const uint64_t cap = now + (uint64_t)MAX_SESSION_SECONDS * 1000ULL;
  if (sessionEndMs > cap) sessionEndMs = cap;

  eventSeq++;
  lastAddedS = add;
  lastPulses = pulses;
  Event e{eventSeq, EV_CREDIT, sessionNo, (uint16_t)min<uint32_t>(pulses, 65535), add, settings.rateVersion,
          remainingSeconds(), now, unixTimeOrZero()};
  pushEvent(e);
  saveCheckpoint();
  Serial.printf("[coin] %lu pulse(s) -> +%lu s, remaining %lu s, seq %lu\n", (unsigned long)pulses,
                (unsigned long)add, (unsigned long)remainingSeconds(), (unsigned long)eventSeq);
  // Report soon (but not inside the pulse train of the next coin).
  statusUploadNeeded = true;
  const uint64_t soon = now + MIN_SYNC_GAP_MS;
  if (nextSyncMs > soon) nextSyncMs = soon;
}

void processPulses() {
  noInterrupts();
  const uint32_t total = isrAcceptedPulses;
  const uint32_t lastUs = isrLastAcceptUs;
  interrupts();
  const uint32_t pending = total - committedPulses;
  if (pending == 0) return;
  // Wait until the coin's pulse train is complete, then credit it as one event.
  if ((uint32_t)(micros() - lastUs) < PULSE_GROUP_TIMEOUT_MS * 1000UL) return;
  committedPulses = total;
  creditPulses(pending);
}

void checkExpiry() {
  if (!sessionRunning) return;
  const uint64_t now = millis64();
  if (now >= sessionEndMs) {
    sessionRunning = false;
    eventSeq++;
    Event e{eventSeq, EV_EXPIRE, sessionNo, 0, 0, settings.rateVersion, 0, now, unixTimeOrZero()};
    pushEvent(e);
    saveCheckpoint();  // remaining=0
    statusUploadNeeded = true;
    Serial.printf("[session] #%lu expired\n", (unsigned long)sessionNo);
    return;
  }
  if (now - lastCheckpointMs >= CHECKPOINT_INTERVAL_S * 1000ULL) saveCheckpoint();
}

void endSessionByAdmin() {
  if (!sessionRunning) return;
  sessionEndMs = millis64();
  checkExpiry();
}

// ============================================================ LCD (only changed rows are written)
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

String minutesText(uint32_t seconds) {
  if (seconds % 60 == 0) return String(seconds / 60) + " min";
  return String(seconds / 60) + "m " + String(seconds % 60) + "s";
}

void updateLcd() {
  static uint64_t last = 0;
  const uint64_t now = millis64();
  if (now - last < LCD_REFRESH_MS) return;
  last = now;
  const uint32_t rem = remainingSeconds();

  if (setupMode) {
    lcdRow(0, "WIFI SETUP MODE");
    lcdRow(1, "AP:" + WiFi.softAPSSID());
    lcdRow(2, "Pass:" + apPassword);
    lcdRow(3, rem ? "Time: " + hms(rem) : "Open 192.168.4.1");
    return;
  }
  lcdRow(0, rem ? "VeNdO  TIMER RUNNING" : "VeNdO  INSERT COIN");
  lcdRow(1, "Time: " + hms(rem));
  if (pairingOpen) {
    lcdRow(2, String("PAIR CODE: ") + pairingCode);
    lcdRow(3, WiFi.localIP().toString());
  } else if (now < infoUntilMs) {
    lcdRow(2, WiFi.isConnected() ? WiFi.localIP().toString() : String("WiFi: not connected"));
    lcdRow(3, deviceId + (cloudState == CLOUD_OK ? " cloud" : ""));
  } else {
    lcdRow(2, "Last added: " + minutesText(lastAddedS));
    // One accepted pulse is one peso (1, 5, 10 and 20 peso coins).
    lcdRow(3, String("Last coin: ") + LCD_PESO + String(lastPulses));
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
  Serial.print("[i2c] devices answering on the bus:");
  uint8_t any = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      Serial.printf(" 0x%02X", addr);
      any++;
    }
    yield();
  }
  Serial.println(any ? "" : " none (nothing connected, or SDA/SCL swapped)");
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

String jsonStr(const String &s, const char *key) {
  String k = String('"') + key + "\":\"";
  int i = s.indexOf(k);
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

// ============================================================ cloud (outbound HTTPS only)
bool timeValid() { return time(nullptr) > 1700000000; }

String apiHost() {
  String b = settings.apiBase;
  int start = b.indexOf("://");
  start = start < 0 ? 0 : start + 3;
  int end = b.indexOf('/', start);
  return b.substring(start, end < 0 ? b.length() : end);
}

// POSTs JSON; returns HTTP status (negative on transport error).
int httpsPostJson(const String &path, const String &body, String &response, bool auth) {
  statusClient.stop();  // only one TLS connection at a time (RAM); its session cache keeps reconnects fast
  BearSSL::WiFiClientSecure client;
  client.setTrustAnchors(trustAnchors);  // full certificate verification
  client.setX509Time(time(nullptr));
  client.setSession(&tlsSession);       // TLS session resumption speeds up later syncs
  if (tlsRxBuffer == 0) {
    // Hostinger currently does not negotiate MFLN; fall back to the full 16 KB buffer.
    tlsRxBuffer = BearSSL::WiFiClientSecure::probeMaxFragmentLength(apiHost(), 443, 4096) ? 4096 : 16384;
    Serial.printf("[cloud] TLS rx buffer %d\n", tlsRxBuffer);
  }
  client.setBufferSizes(tlsRxBuffer, 512);
  client.setTimeout(HTTP_TIMEOUT_MS);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.setReuse(false);
  if (!http.begin(client, settings.apiBase + path)) return -100;
  http.addHeader("Content-Type", "application/json");
  if (auth) {
    http.addHeader("Authorization", "Bearer " + settings.cloudToken);
  }
  const int code = http.POST(body);
  response = code > 0 ? http.getString() : String();
  http.end();
  if (code < 0) {
    char err[80];
    client.getLastSSLError(err, sizeof(err));
    Serial.printf("[cloud] transport error %d (%s) %s\n", code, http.errorToString(code).c_str(), err);
  }
  return code;
}

void cloudEnroll() {
  String body = String("{\"device_type\":\"controller\",\"enrollment_code\":\"") + sanitize(settings.enrollCode, 32) +
                "\",\"name\":\"" + sanitize(settings.deviceName, 60) + "\",\"hardware_id\":\"" + deviceId + "\"}";
  String resp;
  const int code = httpsPostJson("/devices/enroll", body, resp, false);
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

String buildSyncBody(uint8_t &countOut) {
  String b;
  b.reserve(600 + EVENTS_PER_SYNC * 190);
  b += "{\"protocol\":" + String(PROTOCOL_VERSION);
  b += ",\"boot_id\":\"" + bootId + "\"";
  b += ",\"uptime_ms\":" + u64str(millis64());
  b += ",\"fw_version\":\"" FW_VERSION "\"";
  b += ",\"config_version_applied\":" + String(settings.rateVersion);
  b += ",\"status\":{\"session\":\"" + String(remainingSeconds() ? "running" : "idle") + "\"";
  b += ",\"remaining_s\":" + String(remainingSeconds());
  b += ",\"seq\":" + String(eventSeq);
  b += ",\"session_no\":" + String(sessionNo);
  b += ",\"seconds_per_pulse\":" + String(settings.secondsPerPulse);
  b += ",\"rate_version\":" + String(settings.rateVersion);
  b += ",\"wifi_rssi\":" + String(WiFi.RSSI());
  b += ",\"free_heap\":" + String(ESP.getFreeHeap());
  b += ",\"buffered_events\":" + String(evCount);
  b += ",\"dropped_events\":" + String(droppedEvents);
  b += ",\"phone_last_poll_age_s\":" + String(lastPhonePollMs ? (long)((millis64() - lastPhonePollMs) / 1000) : -1L);
  b += "},\"events\":[";
  countOut = min<uint8_t>(evCount, EVENTS_PER_SYNC);
  for (uint8_t i = 0; i < countOut; i++) {
    const Event &e = events[(evStart + i) % EVENT_BUFFER_SIZE];
    if (i) b += ',';
    b += "{\"seq\":" + String(e.seq);
    b += ",\"type\":\"" + String(e.type == EV_CREDIT ? "credit" : "expire") + "\"";
    b += ",\"session_no\":" + String(e.sessionNo);
    b += ",\"pulses\":" + String(e.pulses);
    b += ",\"seconds\":" + String(e.seconds);
    b += ",\"rate_version\":" + String(e.rateVersion);
    b += ",\"remaining_after\":" + String(e.remainingAfter);
    b += ",\"uptime_ms\":" + u64str(e.uptimeMs);
    b += ",\"unix_time\":" + String(e.unixTime) + "}";
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
  String body = buildSyncBody(count);
  String resp;
  const int code = httpsPostJson("/controller/sync", body, resp, true);
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
  if (now < nextSyncMs) return;
  if (!settings.enrollCode.isEmpty()) cloudEnroll();
  else cloudSync();
  // Exponential backoff on failure, capped; normal interval otherwise.
  uint32_t delayS = settings.syncIntervalS;
  if (cloudState == CLOUD_ERROR) delayS = min<uint32_t>(CLOUD_BACKOFF_MAX_S, settings.syncIntervalS << min<uint32_t>(cloudFailures, 5));
  nextSyncMs = millis64() + (uint64_t)delayS * 1000ULL;
}

// ============================================================ status.php upload (existing database)
bool pulsesPending() {
  noInterrupts();
  const bool pending = isrInPulse || isrAcceptedPulses != committedPulses;
  interrupts();
  return pending;
}

bool statusUpload() {
  const uint32_t started = millis();
  statusClient.setX509Time(time(nullptr));
  if (!statusHttp.begin(statusClient, settings.statusUrl)) {
    Serial.println("[status] HTTPS init failed");
    return false;
  }
  statusHttp.addHeader("Content-Type", "application/json");
  statusHttp.addHeader("Authorization", "Bearer " + settings.statusToken);
  statusSequence++;
  char body[300];
  snprintf(body, sizeof(body),
           "{\"device_id\":\"%s\",\"boot_id\":\"%s\",\"sequence\":%lu,\"remaining_seconds\":%lu,\"last_pulses\":%lu}",
           sanitize(settings.statusDeviceId, 64).c_str(), statusBootId, (unsigned long)statusSequence,
           (unsigned long)remainingSeconds(), (unsigned long)lastPulses);
  const int code = statusHttp.POST((uint8_t *)body, strlen(body));
  bool ok = false;
  if (code > 0) {
    String resp = statusHttp.getString();  // read fully so the connection can be reused
    ok = code == 200 && resp.indexOf("\"saved\"") >= 0;
    Serial.printf("[status] upload #%lu: HTTP %d in %lu ms%s\n", (unsigned long)statusSequence, code,
                  (unsigned long)(millis() - started), ok ? "" : " (not saved)");
    if (code == 401 || code == 403) {
      statusState = CLOUD_UNAUTHORIZED;
      // The server's own reason (never contains our token).
      Serial.printf("[status] server says: %s\n", resp.substring(0, 160).c_str());
    }
  } else {
    char err[100];
    statusClient.getLastSSLError(err, sizeof(err));
    Serial.printf("[status] upload failed: %s %s\n", HTTPClient::errorToString(code).c_str(), err);
  }
  statusHttp.end();  // keeps the socket open when the server allows keep-alive
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
  const uint64_t periodic = remainingSeconds() ? STATUS_RUNNING_INTERVAL_MS : STATUS_IDLE_INTERVAL_MS;
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

// ============================================================ local HTTP API (phone)
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

// GET /api/v1/info — unauthenticated, contains no secrets and cannot change anything.
void handleInfo() {
  String b = "{\"ok\":true,\"protocol\":" + String(PROTOCOL_VERSION) + ",\"device_id\":\"" + deviceId +
             "\",\"fw_version\":\"" FW_VERSION "\",\"paired\":" + (settings.pairKeyHex.length() ? "true" : "false") +
             ",\"pairing_open\":" + (pairingOpen ? "true" : "false") + "}";
  sendJson(200, b);
}

// GET /api/v1/status?nonce=<16-64 hex>
// Body is signed: X-VK-Signature = HMAC-SHA256(key, "VK1|status|" + nonce + "|" + body)
void handleStatus() {
  if (settings.pairKeyHex.isEmpty()) return sendError(403, "not_paired");
  const String nonce = server.arg("nonce");
  if (!isHex(nonce, 16, 64)) return sendError(400, "bad_nonce");
  lastPhonePollMs = millis64();
  const uint32_t rem = remainingSeconds();
  String b;
  b.reserve(420);
  b += "{\"ok\":true,\"protocol\":" + String(PROTOCOL_VERSION);
  b += ",\"device_id\":\"" + deviceId + "\"";
  b += ",\"boot_id\":\"" + bootId + "\"";
  b += ",\"uptime_ms\":" + u64str(millis64());
  b += ",\"seq\":" + String(eventSeq);
  b += ",\"session_no\":" + String(sessionNo);
  b += ",\"session\":\"" + String(rem ? "running" : "idle") + "\"";
  b += ",\"remaining_s\":" + String(rem);
  b += ",\"seconds_per_pulse\":" + String(settings.secondsPerPulse);
  b += ",\"rate_version\":" + String(settings.rateVersion);
  b += ",\"last_added_s\":" + String(lastAddedS);
  b += ",\"last_pulses\":" + String(lastPulses);
  b += ",\"resumed\":" + String(resumedFromCheckpoint ? "true" : "false");
  b += ",\"cloud\":\"" + String(cloudStateName()) + "\"";
  b += ",\"status_upload\":\"" + String(cloudStateName(statusState)) + "\"";
  b += ",\"nonce\":\"" + nonce + "\"}";
  server.sendHeader("X-VK-Signature", hmacHex("VK1|status|" + nonce + "|" + b));
  sendJson(200, b);
}

// POST /api/v1/pair  (form: code, phone_id) — only while the physical pairing window is open.
void handlePair() {
  if (!pairingOpen) return sendError(403, "pairing_closed");
  if (pairingAttempts >= PAIRING_MAX_ATTEMPTS) return sendError(429, "too_many_attempts");
  pairingAttempts++;
  const String code = server.arg("code");
  if (!constantTimeEquals(code, String(pairingCode))) {
    if (pairingAttempts >= PAIRING_MAX_ATTEMPTS) pairingOpen = false;
    return sendError(403, "wrong_code");
  }
  settings.pairKeyHex = randomHex(32);
  settings.pairedPhoneId = sanitize(server.arg("phone_id"), 40);
  saveSettings();
  pairingOpen = false;
  lastCmdCounter = 0;
  sendJson(200, "{\"ok\":true,\"device_id\":\"" + deviceId + "\",\"boot_id\":\"" + bootId + "\",\"key\":\"" + settings.pairKeyHex + "\"}");
  Serial.println("[pair] phone paired; previous pairing replaced");
}

// Authenticated phone command: mac = HMAC(key, "VK1|cmd|<name>|<boot_id>|<ctr>"),
// ctr strictly increasing within this boot (prevents replay).
bool verifyCommand(const char *name) {
  if (settings.pairKeyHex.isEmpty()) {
    sendError(403, "not_paired");
    return false;
  }
  const String boot = server.arg("boot_id");
  const uint32_t ctr = strtoul(server.arg("ctr").c_str(), nullptr, 10);
  const String mac = server.arg("mac");
  if (boot != bootId || ctr <= lastCmdCounter) {
    sendError(409, "stale_command");
    return false;
  }
  const String expected = hmacHex(String("VK1|cmd|") + name + "|" + boot + "|" + String(ctr));
  if (!constantTimeEquals(mac, expected)) {
    sendError(403, "bad_mac");
    return false;
  }
  lastCmdCounter = ctr;
  return true;
}

void handleEndSession() {
  if (!verifyCommand("end_session")) return;
  endSessionByAdmin();
  sendJson(200, "{\"ok\":true}");
}

void handleUnpair() {
  if (!verifyCommand("unpair")) return;
  sendJson(200, "{\"ok\":true}");
  settings.pairKeyHex = "";
  settings.pairedPhoneId = "";
  saveSettings();
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
  p += F("\"></label><label>Cloud enrollment code (from the dashboard; optional)<input name=enroll maxlength=16 placeholder='XXXXX-XXXXX'></label>"
         "<label>API base URL<input name=api maxlength=120 value=\"");
  p += htmlEscape(settings.apiBase);
  p += F("\"></label><p>Cloud: ");
  p += settings.cloudToken.length() ? "enrolled" : "not enrolled";
  p += F("</p><h2>Upload to existing status.php</h2><label>Status URL<input name=status_url maxlength=120 value=\"");
  p += htmlEscape(settings.statusUrl);
  p += F("\"></label><label>Status device ID<input name=status_device maxlength=64 value=\"");
  p += htmlEscape(settings.statusDeviceId);
  p += F("\"></label><label>Status upload token (64 characters)<input name=status_token type=password maxlength=128 "
         "autocomplete=off placeholder='");
  p += settings.statusToken.length() ? F("(saved; leave empty to keep)") : F("(not set: upload disabled)");
  p += F("'></label><label><input type=checkbox name=status_clear value=1 style='width:auto'> Remove the saved upload token</label>"
         "<button>Save and restart</button></form>"
         "<p><small>Saving does not change paid time. Phone pairing is separate: hold the FLASH button 3 s in normal mode.</small></p>");
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

// ============================================================ button (pairing / info / setup)
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
  if (!down && wasDown) {
    const uint64_t held = now - downSince;
    if (held >= 50 && held < BUTTON_INFO_MAX_MS) infoUntilMs = now + 10000;
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

  if (!LittleFS.begin()) {
    Serial.println("[fs] mount failed, formatting");
    LittleFS.format();
    LittleFS.begin();
  }
  loadSettings();
  restoreCheckpoint();

  initLcd();  // I2C on D2/D5 must be set up before the coin pin interrupt

  pinMode(COIN_PIN, COIN_USE_INTERNAL_PULLUP ? INPUT_PULLUP : INPUT);
  attachInterrupt(digitalPinToInterrupt(COIN_PIN), onCoinEdge, CHANGE);

  trustAnchors = new BearSSL::X509List(TRUST_ANCHORS_PEM);
  snprintf(statusBootId, sizeof(statusBootId), "%06lx-%08lx-%08lx", (unsigned long)ESP.getChipId(),
           (unsigned long)ESP.random(), (unsigned long)ESP.random());
  statusClient.setTrustAnchors(trustAnchors);  // verified HTTPS, never setInsecure()
  statusClient.setSession(&statusSession);
  statusClient.setTimeout(HTTP_TIMEOUT_MS);
  statusHttp.setReuse(true);
  statusHttp.setTimeout(HTTP_TIMEOUT_MS);
  lastStatusUploadMs = 0;
  startWifi();
  nextSyncMs = millis64() + 5000;
  Serial.printf("[boot] device %s boot %s rate %lu s/pulse%s\n", deviceId.c_str(), bootId.c_str(),
                (unsigned long)settings.secondsPerPulse, resumedFromCheckpoint ? " (session restored)" : "");
}

void logWifiChanges() {
  static bool was = false;
  const bool now = WiFi.isConnected();
  if (now == was || setupMode) return;
  was = now;
  if (now) {
    Serial.printf("[wifi] connected to %s, IP %s (use this IP to pair the phone)\n", WiFi.SSID().c_str(),
                  WiFi.localIP().toString().c_str());
  } else {
    Serial.println("[wifi] disconnected; coins and the timer keep working");
  }
}

// Opens the 2-minute phone pairing window with a fresh 6-digit code.
// Triggered by holding FLASH 3 s or by the USB serial command "pair".
void openPairingWindow() {
  snprintf(pairingCode, sizeof(pairingCode), "%06lu", (unsigned long)(ESP.random() % 1000000UL));
  pairingOpen = true;
  pairingAttempts = 0;
  pairingUntilMs = millis64() + PAIRING_WINDOW_MS;
  // Also on serial (USB = physical access, like the button) in case the LCD is unreadable.
  Serial.printf("[pair] pairing window open for 120 s: code %s, IP %s\n", pairingCode, WiFi.localIP().toString().c_str());
}

// USB serial settings (physical access, like the FLASH button or reflashing):
//   pair                      → open the phone pairing window and print the code
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
      Serial.printf("[status] remaining %lu s, session %s, last added %lu s (%lu pulses), paired %s, IP %s, upload %s\n",
                    (unsigned long)remainingSeconds(), remainingSeconds() ? "running" : "idle", (unsigned long)lastAddedS,
                    (unsigned long)lastPulses, settings.pairKeyHex.length() ? "yes" : "no",
                    WiFi.localIP().toString().c_str(), cloudStateName(statusState));
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
  statusLoop();  // fast path to the existing database (typically 0.1-0.5 s with keep-alive)
  cloudLoop();   // optional /api/v1 dashboard sync; may block ~1-3 s during a TLS handshake
  yield();
}
