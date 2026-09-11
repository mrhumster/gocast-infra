-- 0002_email_verified: add email verification flag to identity users.
-- Follows the baseline convention (IF NOT EXISTS) so it is idempotent.

ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified boolean NOT NULL DEFAULT false;