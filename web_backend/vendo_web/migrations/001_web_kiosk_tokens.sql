-- Browser/kiosk read-only access tokens for GET /api/kiosk-status.php.
-- ADDITIVE ONLY: creates one new table. It does not alter or read the
-- ESP8266 upload credentials and does not modify device_status.
--
-- Each token is bound to exactly one device code (e.g. 'vendo-001'); the
-- endpoint only ever returns that device's status ("device ownership").
-- Only SHA-256 of the token secret is stored. Create rows with
-- tools/make-web-token.php (prints the token once + the INSERT statement).

CREATE TABLE IF NOT EXISTS web_kiosk_tokens (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  public_id CHAR(16) NOT NULL,
  token_hash CHAR(64) NOT NULL,
  device_code VARCHAR(64) NOT NULL,
  label VARCHAR(100) NOT NULL,
  created_at DATETIME NOT NULL,
  expires_at DATETIME NULL,
  revoked_at DATETIME NULL,
  last_used_at DATETIME NULL,
  last_ip VARCHAR(45) NULL,
  window_start INT UNSIGNED NOT NULL DEFAULT 0,
  window_hits INT UNSIGNED NOT NULL DEFAULT 0,
  CONSTRAINT uq_web_kiosk_tokens_public UNIQUE (public_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
