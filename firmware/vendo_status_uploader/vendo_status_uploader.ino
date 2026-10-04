/*
  Vendo coin timer → api/status.php uploader (faster version of the original sketch)

  Same wiring, same pulse filtering and the SAME JSON body sent to status.php:
    {"device_id","boot_id","sequence","remaining_seconds","last_pulses"}
  so nothing on the server has to change.

  Speed changes:
   1. A coin (or expiry) is uploaded as soon as its pulse train is complete
      (≥ MIN_UPLOAD_GAP_MS since the last upload) instead of waiting for the
      10-second upload timer.
   2. The HTTPS connection is kept open and reused (HTTP keep-alive), and the
      TLS session is cached for fast reconnects. A full ESP8266 TLS handshake
      costs ~1–3 s; a reused connection ~0.1–0.4 s.
   3. Trust anchors are parsed once, not on every upload.
  Other fixes:
   4. Heartbeat uploads also while idle (every IDLE_UPLOAD_INTERVAL_MS) so the
      dashboard/browser can tell "idle" from "offline/stale".
   5. LCD row 2 shows Time: HH:MM:SS; "Last added" follows SECONDS_PER_PULSE.
   6. Failed uploads back off (RETRY_DELAY_MS) instead of retrying in a tight loop.
   7. Wi-Fi password and token live in secrets.h (git-ignored), not in the sketch.

  Note: "sequence" counts uploads (as before), not coins. The browser detects
  coins from jumps in remaining time.
*/

#include <Arduino.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <ESP8266WiFi.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClientSecureBearSSL.h>
#include <time.h>
#include <string.h>

#include "secrets.h"  // copy secrets.example.h → secrets.h
#include "certs.h"    // ISRG Root X1, ISRG Root X2, Root YE (verified fingerprints inside)

const char* WIFI_SSID = WIFI_SSID_VALUE;
const char* WIFI_PASSWORD = WIFI_PASSWORD_VALUE;
const char* DEVICE_TOKEN = DEVICE_TOKEN_VALUE;

const char* DEVICE_ID = "vendo-001";
const char* STATUS_URL = "https://vendo-kiosk.ebnleadgen.online/api/status.php";

// NodeMCU / Wemos D1 mini
const uint8_t COIN_PIN = 5;   // D1
const uint8_t LCD_SDA = 4;    // D2
const uint8_t LCD_SCL = 14;   // D5

// 1 / 5 / 10 / 20 pulses = 4 / 20 / 40 / 80 minutes
const uint32_t SECONDS_PER_PULSE = 240;

// Pulse filtering: adjust to your coin slot's actual timing.
const uint32_t MIN_LOW_PULSE_US = 20000;
const uint32_t MAX_LOW_PULSE_US = 250000;
const uint32_t MIN_HIGH_GAP_US = 30000;
// Silence that ends one coin's pulse train. Lower = faster, but it must stay
// longer than the slot's gap between pulses (check with the serial monitor).
const uint32_t COIN_TIMEOUT_US = 400000;

// Upload timing.
const uint32_t MIN_UPLOAD_GAP_MS = 1000;           // after a coin / expiry
const uint32_t RUNNING_UPLOAD_INTERVAL_MS = 10000;  // while time is running
const uint32_t IDLE_UPLOAD_INTERVAL_MS = 30000;     // heartbeat while idle (< 60 s stale threshold)
const uint32_t RETRY_DELAY_MS = 5000;               // after a failed upload
const uint16_t HTTP_TIMEOUT_MS = 6000;

volatile uint32_t pulseCount = 0;
volatile uint32_t lastPulseUs = 0;

volatile bool lowPulseStarted = false;
volatile bool lowPulseEligible = false;
volatile uint32_t lowPulseStartUs = 0;
volatile uint32_t highStartedUs = 0;
volatile uint32_t rejectedPulses = 0;

uint32_t remainingSeconds = 0;
uint32_t lastPulses = 0;
uint32_t lastAddedSeconds = 0;
uint32_t timerTickMs = 0;
uint32_t lastUploadMs = 0;
uint32_t uploadSequence = 0;
uint32_t lastDiagnosticMs = 0;

bool uploadNeeded = true;   // something changed that the server must learn quickly
bool lastUploadFailed = false;
bool tokenValid = false;
bool previouslyConnected = false;

char bootId[40];
char displayedLines[4][21] = {};

LiquidCrystal_I2C* lcd = nullptr;

// Kept for the whole run: parsed once, connection and TLS session reused.
BearSSL::X509List* trustAnchors = nullptr;
BearSSL::Session tlsSession;
BearSSL::WiFiClientSecure tlsClient;
HTTPClient https;

// Count only a completed, valid-width active-low pulse.
void IRAM_ATTR coinPulseISR() {
  uint32_t now = micros();

  if (digitalRead(COIN_PIN) == LOW) {
    if (!lowPulseStarted) {
      lowPulseEligible = (uint32_t)(now - highStartedUs) >= MIN_HIGH_GAP_US;
      lowPulseStartUs = now;
      lowPulseStarted = true;
    }
    return;
  }

  // Signal returned HIGH.
  highStartedUs = now;
  if (!lowPulseStarted) return;

  uint32_t duration = (uint32_t)(now - lowPulseStartUs);
  bool valid = lowPulseEligible && duration >= MIN_LOW_PULSE_US && duration <= MAX_LOW_PULSE_US;
  lowPulseStarted = false;

  if (valid) {
    pulseCount++;
    lastPulseUs = now;
  } else {
    rejectedPulses++;
  }
}

uint8_t findLCDAddress() {
  uint8_t found = 0;
  uint8_t candidates = 0;
  for (uint8_t address = 0x20; address <= 0x3F; address++) {
    if (address > 0x27 && address < 0x38) continue;
    Wire.beginTransmission(address);
    if (Wire.endTransmission() == 0) {
      found = address;
      candidates++;
    }
    yield();
  }
  return candidates == 1 ? found : 0;
}

void printLine(uint8_t row, const char* text) {
  if (lcd == nullptr || row >= 4) return;
  char padded[21];
  memset(padded, ' ', 20);
  padded[20] = '\0';
  for (uint8_t i = 0; i < 20 && text[i]; i++) padded[i] = text[i];
  if (strcmp(padded, displayedLines[row]) == 0) return;  // only rewrite changed rows
  lcd->setCursor(0, row);
  lcd->print(padded);
  memcpy(displayedLines[row], padded, sizeof(padded));
}

void printRemainingTime() {
  Serial.printf("Timer remaining: %lu min %lu sec\n", (unsigned long)(remainingSeconds / 60UL), (unsigned long)(remainingSeconds % 60UL));
}

void updateDisplay() {
  char line[40];
  printLine(0, remainingSeconds > 0 ? "TIMER RUNNING" : "INSERT COIN");
  snprintf(line, sizeof(line), "Time: %02lu:%02lu:%02lu", (unsigned long)(remainingSeconds / 3600UL),
           (unsigned long)((remainingSeconds % 3600UL) / 60UL), (unsigned long)(remainingSeconds % 60UL));
  printLine(1, line);
  if (lastAddedSeconds % 60UL == 0) {
    snprintf(line, sizeof(line), "Last added: %lu min", (unsigned long)(lastAddedSeconds / 60UL));
  } else {
    snprintf(line, sizeof(line), "Last added: %lum%02lus", (unsigned long)(lastAddedSeconds / 60UL), (unsigned long)(lastAddedSeconds % 60UL));
  }
  printLine(2, line);
  snprintf(line, sizeof(line), "Last pulses: %lu", (unsigned long)lastPulses);
  printLine(3, line);
}

bool updateTimer() {
  uint32_t now = millis();
  if (remainingSeconds == 0) {
    timerTickMs = now;
    return false;
  }
  uint32_t elapsed = (uint32_t)(now - timerTickMs) / 1000UL;
  if (elapsed == 0) return false;
  timerTickMs += elapsed * 1000UL;
  if (elapsed >= remainingSeconds) {
    remainingSeconds = 0;
    uploadNeeded = true;  // report expiry promptly
    Serial.println("Time finished.");
  } else {
    remainingSeconds -= elapsed;
  }
  return true;
}

bool processCoins() {
  uint32_t completed = 0;
  noInterrupts();
  uint32_t now = micros();
  if (pulseCount > 0 && !lowPulseStarted && (uint32_t)(now - lastPulseUs) >= COIN_TIMEOUT_US) {
    completed = pulseCount;
    pulseCount = 0;
  }
  interrupts();
  if (completed == 0) return false;

  uint64_t addedSeconds = (uint64_t)completed * SECONDS_PER_PULSE;
  if (addedSeconds > (uint64_t)UINT32_MAX - remainingSeconds) {
    Serial.println("Timer limit reached.");
    return false;
  }
  if (remainingSeconds == 0) timerTickMs = millis();

  remainingSeconds += (uint32_t)addedSeconds;
  lastPulses = completed;
  lastAddedSeconds = (uint32_t)addedSeconds;
  uploadNeeded = true;  // upload right away (see loop)

  Serial.printf("Accepted pulses: %lu | Added: %lu s\n", (unsigned long)lastPulses, (unsigned long)lastAddedSeconds);
  printRemainingTime();
  return true;
}

bool coinPulsesPending() {
  noInterrupts();
  bool pending = pulseCount > 0 || lowPulseStarted;
  interrupts();
  return pending;
}

void reportInputDiagnostics() {
  if ((uint32_t)(millis() - lastDiagnosticMs) < 5000UL) return;
  lastDiagnosticMs = millis();
  noInterrupts();
  uint32_t rejected = rejectedPulses;
  rejectedPulses = 0;
  interrupts();
  if (rejected > 0) Serial.printf("Rejected noise/invalid pulses: %lu\n", (unsigned long)rejected);
  if (digitalRead(COIN_PIN) == LOW) Serial.println("Coin input LOW: check if it remains stuck LOW.");
}

// Returns true when status.php confirmed the upload.
bool uploadStatus() {
  const uint32_t started = millis();
  tlsClient.setX509Time(time(nullptr));

  // With setReuse(true) begin() keeps the existing keep-alive connection when
  // it is still open; otherwise it reconnects using the cached TLS session.
  if (!https.begin(tlsClient, STATUS_URL)) {
    Serial.println("HTTPS initialization failed.");
    return false;
  }
  https.addHeader("Content-Type", "application/json");
  https.addHeader("Authorization", String("Bearer ") + DEVICE_TOKEN);

  updateTimer();  // send the freshest remaining time
  uploadSequence++;

  char body[300];
  snprintf(body, sizeof(body),
           "{\"device_id\":\"%s\",\"boot_id\":\"%s\",\"sequence\":%lu,\"remaining_seconds\":%lu,\"last_pulses\":%lu}",
           DEVICE_ID, bootId, (unsigned long)uploadSequence, (unsigned long)remainingSeconds, (unsigned long)lastPulses);

  const int httpCode = https.POST((uint8_t*)body, strlen(body));
  bool ok = false;
  if (httpCode > 0) {
    String response = https.getString();  // read fully so the connection can be reused
    ok = httpCode == 200 && response.indexOf("\"saved\"") >= 0;
    Serial.printf("Upload #%lu: HTTP %d in %lu ms%s\n", (unsigned long)uploadSequence, httpCode,
                  (unsigned long)(millis() - started), ok ? "" : " (not saved)");
    if (!ok) Serial.println(response);
  } else {
    char tlsError[160];
    tlsClient.getLastSSLError(tlsError, sizeof(tlsError));
    Serial.printf("Upload failed: %s %s\n", HTTPClient::errorToString(httpCode).c_str(), tlsError);
  }
  https.end();  // keeps the socket open when the server allows keep-alive
  return ok;
}

void setup() {
  Serial.begin(115200);
  delay(500);

  Wire.begin(LCD_SDA, LCD_SCL);  // before lcd->init(), so D1 stays the coin input
  Wire.setClock(100000);

  uint8_t address = findLCDAddress();
  if (address != 0) {
    static LiquidCrystal_I2C display(address, 20, 4);
    lcd = &display;
    lcd->init();
    Wire.setClock(100000);
    lcd->backlight();
    lcd->noCursor();
    lcd->noBlink();
    lcd->clear();  // once, at start-up
    delay(5);
    updateDisplay();
    Serial.println("20x4 LCD ready.");
  } else {
    Serial.println("LCD not detected or multiple candidates found.");
  }

  pinMode(COIN_PIN, INPUT_PULLUP);
  delay(300);
  highStartedUs = micros();
  lowPulseStarted = false;
  lowPulseEligible = false;
  attachInterrupt(digitalPinToInterrupt(COIN_PIN), coinPulseISR, CHANGE);

  timerTickMs = millis();
  tokenValid = strlen(DEVICE_TOKEN) == 64;
  if (!tokenValid) Serial.println("Enter your 64-character device token in secrets.h.");

  // TLS: verified certificates (never setInsecure), cached session, keep-alive.
  trustAnchors = new BearSSL::X509List(TRUST_ANCHORS_PEM);
  tlsClient.setTrustAnchors(trustAnchors);
  tlsClient.setSession(&tlsSession);
  tlsClient.setTimeout(HTTP_TIMEOUT_MS);
  https.setReuse(true);
  https.setTimeout(HTTP_TIMEOUT_MS);

  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);  // lower latency for uploads
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  snprintf(bootId, sizeof(bootId), "%06lx-%08lx-%08lx", (unsigned long)ESP.getChipId(), (unsigned long)ESP.random(),
           (unsigned long)ESP.random());

  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
  lastUploadMs = millis() - IDLE_UPLOAD_INTERVAL_MS;

  Serial.println("Ready: valid pulse = 4 minutes.");
  printRemainingTime();
}

void loop() {
  bool changed = updateTimer();
  if (processCoins()) changed = true;
  if (changed) updateDisplay();

  reportInputDiagnostics();

  bool connected = WiFi.status() == WL_CONNECTED;
  if (connected != previouslyConnected) {
    previouslyConnected = connected;
    if (connected) {
      Serial.print("Wi-Fi connected. IP: ");
      Serial.println(WiFi.localIP());
      uploadNeeded = true;
    } else {
      Serial.println("Wi-Fi disconnected. Local timer continues.");
    }
  }

  const uint32_t sinceUpload = millis() - lastUploadMs;
  const bool clockReady = time(nullptr) >= 1700000000;  // needed to validate the certificate
  const uint32_t periodic = remainingSeconds > 0 ? RUNNING_UPLOAD_INTERVAL_MS : IDLE_UPLOAD_INTERVAL_MS;
  const uint32_t minGap = lastUploadFailed ? RETRY_DELAY_MS : MIN_UPLOAD_GAP_MS;
  const bool due = (uploadNeeded && sinceUpload >= minGap) || sinceUpload >= periodic;

  if (connected && clockReady && tokenValid && due && !coinPulsesPending()) {
    const bool ok = uploadStatus();
    lastUploadMs = millis();
    lastUploadFailed = !ok;
    if (ok) uploadNeeded = false;

    // Coins are counted by the interrupt during the upload; credit them now.
    updateTimer();
    processCoins();
    updateDisplay();
  }

  delay(1);
}
