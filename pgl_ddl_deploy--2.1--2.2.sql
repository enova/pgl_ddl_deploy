/* pgl_ddl_deploy--2.1--2.2.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.execute_queued_ddl()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN

/***
Native logical replication does not support row filtering, so as a result,
we need to do processing downstream to ensure we only process rows we care about.

For example, if we propagate some DDL to system 1 and some other to system 2,
all rows will still come through this trigger.  We filter out rows based on
matching pubnames with pg_subscription.subpublications

If a row arrives here (the subscriber), it must mean that it was propagated
***/

-- This handles potential duplicates with multiple subscriptions to same publisher db.
IF EXISTS (
SELECT NEW.*
INTERSECT
SELECT * FROM pgl_ddl_deploy.queue) THEN
    RETURN NULL;
END IF;

IF NEW.message_type = pgl_ddl_deploy.queue_ddl_message_type() AND
    (pgl_ddl_deploy.override() OR ((SELECT COUNT(1) FROM pg_subscription s
    WHERE subpublications && NEW.pubnames) > 0)) THEN

    -- See https://www.postgresql.org/message-id/CAMa1XUh7ZVnBzORqjJKYOv4_pDSDUCvELRbkF0VtW7pvDW9rZw@mail.gmail.com
    IF NEW.message ~* 'pgl_ddl_deploy.notify_subscription_refresh' THEN
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
        (NEW.pubnames[1],
         NULL,
         NULL,
         NULL,
         current_role,
         pg_backend_pid(),
         current_timestamp,
         NEW.message,
         NEW.message,
         FALSE,
         'Unsupported automated ALTER SUBSCRIPTION ... REFRESH PUBLICATION until bugfix');
    ELSE
        EXECUTE 'SET ROLE '||quote_ident(NEW.role)||';';
        EXECUTE NEW.message::TEXT;
    END IF;

    RETURN NEW;
ELSE
    RETURN NULL; 
END IF;

END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.get_altertable_subcmdinfo(pg_ddl_command)
  RETURNS text[] IMMUTABLE STRICT
  AS '$libdir/ddl_deparse', 'get_altertable_subcmdinfo' LANGUAGE C;


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
  p_driver pgl_ddl_deploy.driver,
-- This parameter currently only exists to make testing this function easier
  p_run_anywhere BOOLEAN = FALSE
)
RETURNS BOOLEAN
AS $function$
/****
This function is what will actually be executed on the subscriber when attempting to apply DDL
changed.  It is sent to subscriber(s) via pglogical.replicate_ddl_command.  You can see how it
is called based on the the view pgl_ddl_deploy.event_trigger_schema, which is used to create the
specific event trigger functions that will call this function in different ways depending on
configuration in pgl_ddl_deploy.set_configs.

This function is also used to make testing easier.  The regression suite calls
this function to verify basic functionality. 
****/
DECLARE
  v_succeeded BOOLEAN;
  v_error_message TEXT;
  v_attempt_number INT = 0;
  v_signal pgl_ddl_deploy.signals; 
BEGIN

IF pgl_ddl_deploy.is_subscriber(p_driver, p_set_name, p_provider_name) OR p_run_anywhere THEN

    v_error_message = NULL;
    /****
    If we have configured to kill blocking subscribers, here we set parameters for that:
        1. Whether to cancel or terminate
        2. What lock_timeout to tolerate 
    ****/
    IF p_signal_blocking_subscriber_sessions IS NOT NULL THEN
      v_signal = CASE WHEN p_signal_blocking_subscriber_sessions = 'cancel_then_terminate' THEN 'cancel' ELSE p_signal_blocking_subscriber_sessions END; 
    -- We cannot RESET LOCAL lock_timeout but that should not be necessary because it will end with the transaction
      EXECUTE format('SET LOCAL lock_timeout TO %s', p_lock_timeout);
    END IF;

    /****
    Loop until one of the following takes place:
        1. Successful DDL execution on first attempt 
        2. An unexpected ERROR occurs, which will either RAISE or finish with WARNING based on queue_subscriber_failures configuration 
        3. Blocking sessions are killed until we finally get a successful DDL execution
    ****/
    WHILE TRUE LOOP
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
          -- Change to terminate if we are using cancel_then_terminate and have not been successful after the first iteration 
          IF v_attempt_number > 0 AND p_signal_blocking_subscriber_sessions = 'cancel_then_terminate' AND v_signal = 'cancel' THEN
            v_signal = 'terminate';
          END IF;
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
            v_signal,
            p_nspname,
            p_relname
          );

          -- Continue and retry again but allow a brief pause
          v_attempt_number = v_attempt_number + 1;
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

    /****
    Since this function is only executed on the subscriber, this INSERT adds a log
    to subscriber_logs on the subscriber after execution.

    Note that if we configured queue_subscriber_failures to TRUE in pgl_ddl_deploy.set_configs, then we are
    allowing failed DDL to be caught and logged in this table as succeeded = FALSE for later processing.
    ****/
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
$function$
LANGUAGE plpgsql VOLATILE;


