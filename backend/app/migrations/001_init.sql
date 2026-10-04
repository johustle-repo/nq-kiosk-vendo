-- Vendo Kiosk schema v1 (MySQL 5.7+/MariaDB 10.3+).
-- All timestamps are stored in UTC.
-- The test runner converts this file to SQLite; keep to portable syntax:
-- separate CREATE INDEX statements, CONSTRAINT ... UNIQUE, no ENUM.

CREATE TABLE admins (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(64) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  session_epoch INT NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL,
  last_login_at DATETIME NULL,
  password_changed_at DATETIME NULL,
  CONSTRAINT uq_admins_username UNIQUE (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE kiosks (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  owner_admin_id BIGINT UNSIGNED NOT NULL,
  name VARCHAR(100) NOT NULL,
  created_at DATETIME NOT NULL,
  CONSTRAINT fk_kiosks_owner FOREIGN KEY (owner_admin_id) REFERENCES admins (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_kiosks_owner ON kiosks (owner_admin_id);

-- Every configuration change creates a new immutable version row.
CREATE TABLE kiosk_configs (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  kiosk_id BIGINT UNSIGNED NOT NULL,
  version INT NOT NULL,
  seconds_per_pulse INT NOT NULL,
  allowed_packages TEXT NOT NULL,
  local_loss_timeout_s INT NOT NULL,
  controller_sync_interval_s INT NOT NULL,
  created_by_admin_id BIGINT UNSIGNED NULL,
  created_at DATETIME NOT NULL,
  CONSTRAINT uq_kiosk_configs_version UNIQUE (kiosk_id, version),
  CONSTRAINT fk_kiosk_configs_kiosk FOREIGN KEY (kiosk_id) REFERENCES kiosks (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Phones and ESP8266 coin controllers. token_hash = SHA-256 of the secret part
-- of the device token; the plaintext token is shown to the device exactly once.
CREATE TABLE devices (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  kiosk_id BIGINT UNSIGNED NOT NULL,
  device_type VARCHAR(16) NOT NULL,
  public_id VARCHAR(32) NOT NULL,
  token_hash CHAR(64) NOT NULL,
  name VARCHAR(100) NOT NULL,
  hardware_id VARCHAR(64) NULL,
  created_at DATETIME NOT NULL,
  revoked_at DATETIME NULL,
  last_seen_at DATETIME NULL,
  last_ip VARCHAR(45) NULL,
  sw_version VARCHAR(32) NULL,
  config_version_applied INT NULL,
  status_json TEXT NULL,
  status_boot_id VARCHAR(16) NULL,
  status_uptime_ms BIGINT NULL,
  status_reported_at DATETIME NULL,
  CONSTRAINT uq_devices_public_id UNIQUE (public_id),
  CONSTRAINT fk_devices_kiosk FOREIGN KEY (kiosk_id) REFERENCES kiosks (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_devices_kiosk ON devices (kiosk_id);

CREATE TABLE enrollment_codes (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  kiosk_id BIGINT UNSIGNED NOT NULL,
  device_type VARCHAR(16) NOT NULL,
  code_hash CHAR(64) NOT NULL,
  created_by_admin_id BIGINT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL,
  expires_at DATETIME NOT NULL,
  used_at DATETIME NULL,
  used_by_device_id BIGINT UNSIGNED NULL,
  CONSTRAINT uq_enrollment_code UNIQUE (code_hash),
  CONSTRAINT fk_enrollment_kiosk FOREIGN KEY (kiosk_id) REFERENCES kiosks (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Coin controller events. (device_id, boot_id, seq) is the idempotency key:
-- a retried upload of the same event is ignored, never double-counted.
CREATE TABLE coin_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  device_id BIGINT UNSIGNED NOT NULL,
  kiosk_id BIGINT UNSIGNED NOT NULL,
  boot_id VARCHAR(16) NOT NULL,
  seq INT NOT NULL,
  event_type VARCHAR(16) NOT NULL,
  session_no INT NOT NULL,
  pulses INT NOT NULL DEFAULT 0,
  seconds_added INT NOT NULL DEFAULT 0,
  rate_version INT NOT NULL DEFAULT 0,
  remaining_after INT NOT NULL DEFAULT 0,
  device_uptime_ms BIGINT NOT NULL,
  occurred_at DATETIME NOT NULL,
  received_at DATETIME NOT NULL,
  CONSTRAINT uq_coin_event UNIQUE (device_id, boot_id, seq),
  CONSTRAINT fk_coin_events_device FOREIGN KEY (device_id) REFERENCES devices (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_coin_events_kiosk ON coin_events (kiosk_id, occurred_at);

CREATE TABLE sessions (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  device_id BIGINT UNSIGNED NOT NULL,
  kiosk_id BIGINT UNSIGNED NOT NULL,
  boot_id VARCHAR(16) NOT NULL,
  session_no INT NOT NULL,
  started_at DATETIME NOT NULL,
  last_credit_at DATETIME NOT NULL,
  ended_at DATETIME NULL,
  end_reason VARCHAR(32) NULL,
  total_pulses INT NOT NULL DEFAULT 0,
  total_seconds INT NOT NULL DEFAULT 0,
  credit_count INT NOT NULL DEFAULT 0,
  CONSTRAINT uq_session UNIQUE (device_id, boot_id, session_no),
  CONSTRAINT fk_sessions_device FOREIGN KEY (device_id) REFERENCES devices (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_sessions_kiosk ON sessions (kiosk_id, started_at);

CREATE TABLE audit_log (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  admin_id BIGINT UNSIGNED NULL,
  kiosk_id BIGINT UNSIGNED NULL,
  device_id BIGINT UNSIGNED NULL,
  action VARCHAR(64) NOT NULL,
  details TEXT NULL,
  ip VARCHAR(45) NULL,
  created_at DATETIME NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_audit_admin ON audit_log (admin_id, created_at);
CREATE INDEX idx_audit_kiosk ON audit_log (kiosk_id, created_at);

CREATE TABLE rate_limits (
  bucket VARCHAR(160) NOT NULL PRIMARY KEY,
  window_start BIGINT NOT NULL,
  hits INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
