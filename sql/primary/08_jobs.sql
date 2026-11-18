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

-- Requirement 5: confirm pending operations with the parity of the current second, every 3 seconds.
SELECT cron.schedule('confirm-operations', '3 seconds',
                     'SELECT ops.confirm_operations_by_parity()') AS confirm_operations_job_id;

-- Housekeeping: prune cron.job_run_details and the audit logs (keeps 3 days), daily 00:30 UTC.
SELECT cron.schedule('housekeeping', '30 0 * * *',
                     'SELECT ops.housekeeping()') AS housekeeping_job_id;
