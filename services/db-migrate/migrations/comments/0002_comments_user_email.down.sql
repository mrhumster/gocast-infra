-- 0002_comments_user_email rollback drops the denormalized column

ALTER TABLE comments DROP COLUMN user_email;