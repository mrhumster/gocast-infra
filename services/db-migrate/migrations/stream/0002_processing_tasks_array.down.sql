-- 0002 down: revert tasks array back to the legacy single-object shape.
-- Inherently lossy: only the first task (transcode) is preserved and the
-- task_type key is dropped. Run only when rolling back to the previous
-- stream-service that expects an object.
UPDATE streams
SET processing = (
    SELECT e - 'task_type'
    FROM jsonb_array_elements(processing) e
    LIMIT 1
)
WHERE processing IS NOT NULL
  AND jsonb_typeof(processing) = 'array';