// Shared types. Kept in a header so the Arduino IDE's generated function
// prototypes (inserted near the top of the .ino) can see them.
#pragma once
#include <Arduino.h>
#include "config.h"

struct Settings {
  String wifiSsid;
  String wifiPass;
  String deviceName = "Coin controller";
  String apiBase = DEFAULT_API_BASE;
  String cloudToken;      // per-device credential from enrollment (secret)
  String enrollCode;      // pending one-time code, cleared after enrollment
  uint32_t secondsPerPulse = DEFAULT_SECONDS_PER_PULSE;
  uint32_t rateVersion = 0;  // cloud config version that set the rate (0 = firmware default)
  uint32_t syncIntervalS = DEFAULT_SYNC_INTERVAL_S;
  // Upload to the existing api/status.php (device_status table) — tablet 1 only.
  String statusUrl = DEFAULT_STATUS_URL;
  String statusDeviceId = DEFAULT_STATUS_DEVICE_ID;
  String statusToken;  // secret; empty = status.php upload disabled
};

// One tablet ("station") served by this coin box. The coin box is the
// authority for each tablet's paid time.
struct Station {
  bool running = false;
  uint64_t endMs = 0;
  uint32_t sessionNo = 0;
  uint32_t lastAddedS = 0;
  uint32_t lastPulses = 0;
  String pairKeyHex;       // 32-byte HMAC key shared with this tablet (secret)
  String pairedPhoneId;
  uint32_t lastCmdCounter = 0;
  uint64_t lastPhonePollMs = 0;
};

enum EventType : uint8_t {
  EV_CREDIT = 1,        // coins credited to the selected tablet
  EV_EXPIRE = 2,        // a tablet's time ran out
  EV_HELD = 3,          // coins inserted with no tablet selected (station 0)
  EV_ASSIGN = 4,        // held coins given to a tablet by the attendant
  EV_ADMIN_CREDIT = 5,  // free time added from the dashboard
  EV_ADMIN_END = 6,     // session ended from the dashboard or a tablet admin
};

struct Event {
  uint32_t seq;
  uint8_t type;
  uint8_t station;  // 1..MAX_STATIONS, 0 = held
  uint32_t sessionNo;
  uint16_t pulses;
  uint32_t seconds;
  uint32_t rateVersion;
  uint32_t remainingAfter;
  uint64_t uptimeMs;
  uint32_t unixTime;
  uint32_t commandId;  // dashboard command that caused it (0 = none)
};

enum CloudState { CLOUD_DISABLED, CLOUD_WAIT_TIME, CLOUD_OK, CLOUD_ERROR, CLOUD_UNAUTHORIZED };
