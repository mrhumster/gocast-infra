-- 0003: track whether face detection has completed successfully for a stream.
-- The flag is set by stream-service when the "faces" processing task finishes
-- with progress = 100 and no error, and reset via the internal
-- POST /stream/:id/faces/reset endpoint when a person is deleted so the stream
-- can be re-detected.
ALTER TABLE streams
    ADD COLUMN IF NOT EXISTS faces_detected boolean NOT NULL DEFAULT false;