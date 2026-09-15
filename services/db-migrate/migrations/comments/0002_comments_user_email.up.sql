-- 0002_comments_user_email stores the author email for display
-- email is denormalized from the JWT email claim at comment creation
-- existing rows are backfilled once from the shared users table

ALTER TABLE comments ADD COLUMN user_email text;

UPDATE comments c
SET user_email = u.email
FROM users u
WHERE c.user_id = u.id
  AND c.user_email IS NULL;