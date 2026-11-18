-- =============================================================================
-- 08_jobs.sql  (primary only)
-- pg_cron schedules (D-04). cron.schedule(job_name, ...) is an upsert by name,
-- so this script is safe to re-run.
--
-- pg_cron interval syntax '[1-59] seconds' runs the job every N seconds; a job never
-- overlaps with itself (if a run is still active, the next one waits).
-- Jobs run as background workers (cron.use_background_workers = on), in this database.
-- =============================================================================

-- Requirement 4: one pending operation every 5 seconds.
SELECT cron.schedule('insert-operation', '5 seconds',
                     'SELECT ops.insert_random_operation()') AS insert_operation_job_id;

-- Housekeeping: two second-level jobs write ~46k rows/day into cron.job_run_details.
-- Keep 3 days of history (enough for verification and troubleshooting).
SELECT cron.schedule('cron-history-cleanup', '30 0 * * *',
                     $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '3 days'$$)
       AS cron_history_cleanup_job_id;
