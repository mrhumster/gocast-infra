-- 0002: migrate legacy single-object `processing` JSON to the tasks array.
-- The stream processing column is now a JSON array of StreamProcessingTask
-- entries (task_type = "transcode" | "thumbnail"). Existing rows were written
-- as a single object (progress/steps/error/task_id) which maps to the
-- transcode task. Rows that already store an array are left untouched.
UPDATE streams
SET processing = jsonb_build_array(
    COALESCE(processing, '{}'::jsonb) || jsonb_build_object('task_type', 'transcode')
)
WHERE processing IS NOT NULL
  AND jsonb_typeof(processing) = 'object';