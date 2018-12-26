CREATE OR REPLACE FUNCTION pgl_ddl_deploy.subscriber_command
(
  p_provider_name NAME,
  p_set_name TEXT[],
  p_nspname NAME,
  p_relname NAME,
  p_ddl_sql_sent TEXT,
  p_full_ddl TEXT,
  p_pid INT,
  p_set_config_id INT,
  p_queue_subscriber_failures BOOLEAN,
  p_signal_blocking_subscriber_sessions pgl_ddl_deploy.signals,
  p_lock_timeout INT,
-- This parameter currently only exists to make testing this function easier
  p_run_anywhere BOOLEAN = FALSE
)
RETURNS BOOLEAN
AS $pgl_ddl_deploy_sql$
DECLARE
  v_succeeded BOOLEAN;
  v_error_message TEXT;
BEGIN

--Only run on subscriber with this replication set, and matching provider node name
IF EXISTS (SELECT 1
              FROM pglogical.subscription s
              INNER JOIN pglogical.node n
                ON n.node_id = s.sub_origin
                AND n.node_name = p_provider_name
              WHERE sub_replication_sets && p_set_name) OR p_run_anywhere THEN

    v_error_message = NULL;
    WHILE TRUE LOOP
    IF p_signal_blocking_subscriber_sessions IS NOT NULL THEN
    -- We cannot RESET LOCAL lock_timeout but that should not be necessary because it will end with the transaction
      EXECUTE format('SET LOCAL lock_timeout TO %s', p_lock_timeout);
    END IF;
    BEGIN

     --Execute DDL
     RAISE LOG 'pgl_ddl_deploy attempting execution: %', p_full_ddl;
     
    --Execute DDL - the reason we use execute here is partly to handle no trailing semicolon
     EXECUTE p_full_ddl;

     v_succeeded = TRUE;
     EXIT;

    EXCEPTION
      WHEN lock_not_available THEN
        IF p_signal_blocking_subscriber_sessions IS NOT NULL THEN
          INSERT INTO pgl_ddl_deploy.killed_blockers
            (signal,
            successful,
            pid,
            executed_at,
            usename,
            client_addr,
            xact_start,
            state_change,
            state,
            query,
            reported)
          SELECT
            signal,
            successful,
            pid,
            executed_at,
            usename,
            client_addr,
            xact_start,
            state_change,
            state,
            query,
            reported
          FROM pgl_ddl_deploy.kill_blockers(
            p_signal_blocking_subscriber_sessions,
            p_nspname,
            p_relname
          );

          -- Continue and retry again but allow a brief pause
          PERFORM pg_sleep(3);
        ELSE
          -- If p_signal_blocking_subscriber_sessions is not configured but we hit a lock_timeout,
          -- then the replication user or cluster is configured with a global lock_timeout.  Raise in this case.
          RAISE;
        END IF;
      WHEN OTHERS THEN
        IF p_queue_subscriber_failures THEN
          RAISE WARNING 'Subscriber DDL failed with errors (see pgl_ddl_deploy.subscriber_logs): %', SQLERRM;
          v_succeeded = FALSE;
          v_error_message = SQLERRM;
          EXIT;
        ELSE
          RAISE;
        END IF;
    END;
    END LOOP;

    INSERT INTO pgl_ddl_deploy.subscriber_logs
    (set_name,
     provider_pid,
     provider_node_name,
     provider_set_config_id,
     executed_as_role,
     subscriber_pid,
     executed_at,
     ddl_sql,
     full_ddl_sql,
     succeeded,
     error_message)
    VALUES
    (p_set_name,
     p_pid,
     p_provider_name,
     p_set_config_id,
     current_role,
     pg_backend_pid(),
     current_timestamp,
     p_ddl_sql_sent,
     p_full_ddl,
     v_succeeded,
     v_error_message);

END IF;

RETURN v_succeeded;

END;
$pgl_ddl_deploy_sql$
LANGUAGE plpgsql VOLATILE;
