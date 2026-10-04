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
  String pairKeyHex;      // 32-byte HMAC key shared with the paired phone (secret)
  String pairedPhoneId;
  uint32_t secondsPerPulse = DEFAULT_SECONDS_PER_PULSE;
  uint32_t rateVersion = 0;  // cloud config version that set the rate (0 = firmware default)
  uint32_t syncIntervalS = DEFAULT_SYNC_INTERVAL_S;
  // Upload to the existing api/status.php (device_status table).
  String statusUrl = DEFAULT_STATUS_URL;
  String statusDeviceId = DEFAULT_STATUS_DEVICE_ID;
  String statusToken;  // secret; empty = status.php upload disabled
};

enum EventType : uint8_t { EV_CREDIT = 1, EV_EXPIRE = 2 };

struct Event {
  uint32_t seq;
  uint8_t type;
  uint32_t sessionNo;
  uint16_t pulses;
  uint32_t seconds;
  uint32_t rateVersion;
  uint32_t remainingAfter;
  uint64_t uptimeMs;
  uint32_t unixTime;
};

enum CloudState { CLOUD_DISABLED, CLOUD_WAIT_TIME, CLOUD_OK, CLOUD_ERROR, CLOUD_UNAUTHORIZED };
