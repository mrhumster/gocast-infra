-- 0004 down: drop the single-file export state table.
DROP INDEX IF EXISTS idx_stream_exports_stream_id;
DROP INDEX IF EXISTS idx_stream_exports_user_id;
DROP INDEX IF EXISTS idx_stream_exports_deleted_at;
DROP TABLE IF EXISTS stream_exports;
