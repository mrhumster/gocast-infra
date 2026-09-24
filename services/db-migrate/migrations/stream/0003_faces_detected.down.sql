-- 0003 down: drop the faces detection flag.
ALTER TABLE streams
    DROP COLUMN IF EXISTS faces_detected;