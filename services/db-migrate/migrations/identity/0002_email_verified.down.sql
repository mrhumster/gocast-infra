-- 0002_email_verified: drop email verification flag.

ALTER TABLE users DROP COLUMN IF EXISTS email_verified;