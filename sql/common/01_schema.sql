-- =============================================================================
-- 01_schema.sql  (common: primary + replica)
-- Application schema and extensions.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ops;
COMMENT ON SCHEMA ops IS 'Operations domain (test assignment). See docs/00-task.md.';

-- Scheduler for the second-level jobs (D-04). Must live in cron.database_name (= this DB).
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- gen_random_uuid() is built into PostgreSQL 13+, no pgcrypto needed.
