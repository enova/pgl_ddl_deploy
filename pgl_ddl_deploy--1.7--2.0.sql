/* pgl_ddl_deploy--1.7--2.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

/*
 * We need to re-deploy the trigger function definitions
 * which will have changed with this extension update. So
 * here we undeploy them, and save which ones we need to
 * recreate later.
*/
DO $$
BEGIN

IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname = 'pgl_ddl_deploy' AND viewname = 'event_trigger_schema') THEN 

DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT id, pgl_ddl_deploy.undeploy(id) AS undeployed
FROM pgl_ddl_deploy.event_trigger_schema
WHERE is_deployed;

ELSE

DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT NULL::INT AS id;

END IF;
END$$;

CREATE TYPE pgl_ddl_deploy.driver AS ENUM ('pglogical', 'native');
-- Not possible that any existing config would be native, so:
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN driver pgl_ddl_deploy.driver NOT NULL DEFAULT 'pglogical';
DROP FUNCTION IF EXISTS pgl_ddl_deploy.rep_set_table_wrapper();
DROP FUNCTION IF EXISTS pgl_ddl_deploy.deployment_check_count(integer, text, text);
DROP FUNCTION pgl_ddl_deploy.subscriber_command
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
  p_run_anywhere BOOLEAN
);

CREATE TABLE pgl_ddl_deploy.queue(
queued_at timestamp with time zone not null,
role name not null,
pubnames text[],
message_type "char" not null,
message text not null
);
COMMENT ON TABLE pgl_ddl_deploy.queue IS 'Modeled on the pglogical.queue table for native logical replication ddl';
ALTER TABLE pgl_ddl_deploy.queue REPLICA IDENTITY FULL;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.override() RETURNS BOOLEAN AS $BODY$
BEGIN
RETURN FALSE;
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;

-- NOTE - this duplicates execute_queued_ddl.sql function file but is executed here for the upgrade/build path
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

CREATE TRIGGER execute_queued_ddl
BEFORE INSERT ON pgl_ddl_deploy.queue
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.execute_queued_ddl();

-- This must only fire on the replica
ALTER TABLE pgl_ddl_deploy.queue ENABLE REPLICA TRIGGER execute_queued_ddl;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.replicate_ddl_command(command text, pubnames text[]) 
 RETURNS BOOLEAN 
 LANGUAGE plpgsql
AS $function$
-- Modeled after pglogical's replicate_ddl_command but in support of native logical replication
BEGIN

-- NOTE: pglogical uses clock_timestamp() to log queued_at times and we do the same here
INSERT INTO pgl_ddl_deploy.queue (queued_at, role, pubnames, message_type, message)
VALUES (clock_timestamp(), current_role, pubnames, pgl_ddl_deploy.queue_ddl_message_type(), command);

RETURN TRUE;

END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_table_to_replication(p_driver pgl_ddl_deploy.driver, p_set_name name, p_relation regclass, p_synchronize_data boolean DEFAULT false)
 RETURNS BOOLEAN 
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_schema NAME;
    v_table NAME;
    v_result BOOLEAN = false;
BEGIN
IF p_driver = 'pglogical' THEN

    SELECT pglogical.replication_set_add_table(
            set_name:=p_set_name
            ,relation:=p_relation
            ,synchronize_data:=p_synchronize_data
          ) INTO v_result;

ELSEIF p_driver = 'native' THEN

    SELECT nspname, relname INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_relation::OID;

    EXECUTE 'ALTER PUBLICATION '||quote_ident(p_set_name)||' ADD TABLE '||quote_ident(v_schema)||'.'||quote_ident(v_table)||';';
    
    -- We use true to synchronize data here, not taking the value from p_synchronize_data.  This is because of the different way
    -- that native logical works, and that changes are not queued from the time of the table being added to replication.  Thus, we
    -- by default WILL use COPY_DATA = true

    -- This needs to be in a DO block currently because of how the DDL is processed on the subscriber.
    PERFORM pgl_ddl_deploy.replicate_ddl_command($$DO $AUTO_REPLICATE_BLOCK$
    BEGIN
    PERFORM pgl_ddl_deploy.notify_subscription_refresh('$$||p_set_name||$$', true);
    END$AUTO_REPLICATE_BLOCK$;$$, array[p_set_name]);
    v_result = true;

ELSE

RAISE EXCEPTION 'Unsupported driver specified';

END IF;

RETURN v_result;

END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.notify_subscription_refresh(p_set_name name, p_copy_data boolean DEFAULT TRUE)
 RETURNS BOOLEAN 
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rec RECORD;
    v_sql TEXT;
BEGIN

    IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subpublications && array[p_set_name::text]) THEN
        RAISE EXCEPTION 'No subscription to publication % exists', p_set_name;
    END IF; 

    FOR v_rec IN
        SELECT unnest(subpublications) AS pubname, subname
        FROM pg_subscription
        WHERE subpublications && array[p_set_name::text]
    LOOP

    v_sql = $$ALTER SUBSCRIPTION $$||quote_ident(v_rec.subname)||$$ REFRESH PUBLICATION WITH ( COPY_DATA = '$$||p_copy_data||$$');$$;
    RAISE LOG 'pgl_ddl_deploy executing: %', v_sql;
    EXECUTE v_sql;

    END LOOP;

RETURN TRUE;

END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.rep_set_table_wrapper()
 RETURNS TABLE (id OID, relid REGCLASS, name NAME, driver pgl_ddl_deploy.driver)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
/*****
This handles the rename of pglogical.replication_set_relation to pglogical.replication_set_table from version 1 to 2
 */
BEGIN

IF current_setting('server_version_num')::INT < 100000 THEN 
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_table') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set_table r
        JOIN pglogical.replication_set rs USING (set_id);

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_relation') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set_relation r
        JOIN pglogical.replication_set rs USING (set_id);

    ELSE
        RAISE EXCEPTION 'No table pglogical.replication_set_relation or pglogical.replication_set_table found';
    END IF;

ELSE
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
        RETURN QUERY
        SELECT p.oid AS id, prrelid::REGCLASS AS relid, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p
        JOIN pg_publication_rel ppr ON ppr.prpubid = p.oid;

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_table') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set_table r
        JOIN pglogical.replication_set rs USING (set_id)
        UNION ALL
        SELECT p.oid AS id, prrelid::REGCLASS AS relid, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p
        JOIN pg_publication_rel ppr ON ppr.prpubid = p.oid;

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_relation') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver 
        FROM pglogical.replication_set_relation r
        JOIN pglogical.replication_set rs USING (set_id)
        UNION ALL
        SELECT p.oid AS id, prrelid::REGCLASS AS relid, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p
        JOIN pg_publication_rel ppr ON ppr.prpubid = p.oid;
    END IF;
END IF;

END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.rep_set_wrapper()
 RETURNS TABLE (id OID, name NAME, driver pgl_ddl_deploy.driver)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
/*****
This handles the rename of pglogical.replication_set_relation to pglogical.replication_set_table from version 1 to 2
 */
BEGIN

IF current_setting('server_version_num')::INT < 100000 THEN 
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical') THEN
        RETURN QUERY
        SELECT set_id AS id, set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set rs;

    ELSE
        RAISE EXCEPTION 'pglogical required for version prior to Postgres 10';
    END IF;

ELSE
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
        RETURN QUERY
        SELECT p.oid AS id, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p;

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical') THEN
        RETURN QUERY
        SELECT set_id AS id, set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set rs
        UNION ALL
        SELECT p.oid AS id, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p;
    ELSE
        RAISE EXCEPTION 'Unexpected exception';
    END IF;


END IF;

END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check_count(p_set_config_id integer, p_set_name text, p_include_schema_regex text, p_driver pgl_ddl_deploy.driver)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
BEGIN

--If the check is not applicable, pass it
IF p_set_config_id IS NULL THEN
  RETURN TRUE;
END IF;

SELECT COUNT(1)
INTO v_count
FROM pg_namespace n
  INNER JOIN pg_class c ON n.oid = c.relnamespace
    AND c.relpersistence = 'p'
  WHERE n.nspname ~* p_include_schema_regex
    AND n.nspname !~* c_exclude_always
    AND EXISTS (SELECT 1
    FROM pg_index i
    WHERE i.indrelid = c.oid
      AND i.indisprimary)
    AND NOT EXISTS
    (SELECT 1
    FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
    WHERE rsr.name = p_set_name
      AND rsr.relid = c.oid
      AND rsr.driver = p_driver);

IF v_count > 0 THEN
  RAISE WARNING $ERR$
  Deployment of auto-replication for id % set_name % failed
  because % tables are already queued to be added to replication
  based on your configuration.  These tables need to be added to
  replication manually and synced, otherwise change your configuration.
  Debug query: %$ERR$,
    p_set_config_id,
    p_set_name,
    v_count,
    $SQL$
    SELECT n.nspname, c.relname
    FROM pg_namespace n
      INNER JOIN pg_class c ON n.oid = c.relnamespace
        AND c.relpersistence = 'p'
      WHERE n.nspname ~* '$SQL$||p_include_schema_regex||$SQL$'
        AND n.nspname !~* '$SQL$||c_exclude_always||$SQL$'
        AND EXISTS (SELECT 1
        FROM pg_index i
        WHERE i.indrelid = c.oid
          AND i.indisprimary)
        AND NOT EXISTS
        (SELECT 1
        FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
        WHERE rsr.name = '$SQL$||p_set_name||$SQL$'
          AND rsr.relid = c.oid
          AND rsr.driver = (SELECT driver FROM pgl_ddl_deploy.set_configs WHERE set_name = '$SQL$||p_set_name||$SQL$'));
    $SQL$;
    RETURN FALSE;
END IF;

RETURN TRUE;

END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check_wrapper(p_set_config_id integer, p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_set_config_id INT;
  c_include_schema_regex TEXT;
  v_include_only_repset_tables BOOLEAN;
  v_ddl_only_replication BOOLEAN;
  c_set_name TEXT;
  v_driver pgl_ddl_deploy.driver;
BEGIN

IF p_set_config_id IS NOT NULL AND p_set_name IS NOT NULL THEN
    RAISE EXCEPTION 'This function can only be called with one of the two arguments set.';
END IF;

IF NOT EXISTS (SELECT 1 FROM pgl_ddl_deploy.set_configs WHERE ((p_set_name is null and id = p_set_config_id) OR (p_set_config_id is null and set_name = p_set_name))) THEN
  RETURN FALSE;                                               
END IF;

/***
  This check is only applicable to NON-include_only_repset_tables and sets using CREATE TABLE events.
  It is also bypassed if ddl_only_replication is true in which we never auto-add tables to replication.
  We re-assign set_config_id because we want to know if no records are found, leading to NULL
*/
SELECT id, include_schema_regex, set_name, include_only_repset_tables, ddl_only_replication, driver
INTO c_set_config_id, c_include_schema_regex, c_set_name, v_include_only_repset_tables, v_ddl_only_replication, v_driver
FROM pgl_ddl_deploy.set_configs
WHERE ((p_set_name is null and id = p_set_config_id)
  OR (p_set_config_id is null and set_name = p_set_name))
  AND create_tags && '{"CREATE TABLE"}'::TEXT[];

IF v_include_only_repset_tables OR v_ddl_only_replication THEN
    RETURN TRUE;
END IF;

RETURN pgl_ddl_deploy.deployment_check_count(c_set_config_id, c_set_name, c_include_schema_regex, v_driver);

END;
$function$;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.is_subscriber(p_driver pgl_ddl_deploy.driver, p_name TEXT[], p_provider_name NAME = NULL)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN

IF p_driver = 'pglogical' THEN

    RETURN EXISTS (SELECT 1
                  FROM pglogical.subscription s
                  INNER JOIN pglogical.node n
                    ON n.node_id = s.sub_origin
                    AND n.node_name = p_provider_name
                  WHERE sub_replication_sets && p_name);

ELSEIF p_driver = 'native' THEN

    RETURN EXISTS (SELECT 1
                  FROM pg_subscription s
                  WHERE subpublications && p_name);

ELSE

RAISE EXCEPTION 'Unsupported driver specified';

END IF;

END;
$function$
;


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
AS $pgl_ddl_deploy_sql$
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
$pgl_ddl_deploy_sql$
LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.queue_ddl_message_type()
 RETURNS "char" 
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT 'Q'::"char";
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.provider_node_name(p_driver pgl_ddl_deploy.driver)
 RETURNS NAME 
 LANGUAGE plpgsql
AS $function$
DECLARE v_node_name NAME;
BEGIN

IF p_driver = 'pglogical' THEN

    SELECT n.node_name INTO v_node_name
    FROM pglogical.node n
    INNER JOIN pglogical.local_node ln
    USING (node_id);
    RETURN v_node_name;

ELSEIF p_driver = 'native' THEN

    RETURN NULL::NAME; 

ELSE

RAISE EXCEPTION 'Unsupported driver specified';

END IF;

END;
$function$
;


CREATE OR REPLACE VIEW pgl_ddl_deploy.event_trigger_schema AS
WITH vars AS
(SELECT
  sc.id,
   set_name,
  'pgl_ddl_deploy.auto_rep_ddl_create_'||sc.id::TEXT||'_'||set_name AS auto_replication_create_function_name,
  'pgl_ddl_deploy.auto_rep_ddl_drop_'||sc.id::TEXT||'_'||set_name AS auto_replication_drop_function_name,
  'pgl_ddl_deploy.auto_rep_ddl_unsupp_'||sc.id::TEXT||'_'||set_name AS auto_replication_unsupported_function_name,
  'auto_rep_ddl_create_'||sc.id::TEXT||'_'||set_name AS auto_replication_create_trigger_name,
  'auto_rep_ddl_drop_'||sc.id::TEXT||'_'||set_name AS auto_replication_drop_trigger_name,
  'auto_rep_ddl_unsupp_'||sc.id::TEXT||'_'||set_name AS auto_replication_unsupported_trigger_name,
  include_schema_regex,
  include_only_repset_tables,
  create_tags,
  drop_tags,
  ddl_only_replication,
  include_everything,
  signal_blocking_subscriber_sessions,
  subscriber_lock_timeout,
  sc.driver,

  /****
  These constants in DECLARE portion of all functions is identical and can be shared
   */
  $BUILD$
  c_search_path TEXT = (SELECT current_setting('search_path'));
  c_provider_name TEXT;
   --TODO: How do I decide which replication set we care about?
  v_pid INT = pg_backend_pid();
  v_rec RECORD;
  v_ddl_sql_raw TEXT;
  v_ddl_sql_sent TEXT;
  v_full_ddl TEXT;
  v_sql_tags TEXT[];
  v_cmd_rec RECORD;
  v_subcmd_rec RECORD;
  v_excluded_subcommands TEXT;
  v_contains_any_valid_subcommand INT;

  /*****
  We need to strip the DDL of:
    1. Transaction begin and commit, which cannot run inside plpgsql
  *****/
  v_ddl_strip_regex TEXT = '(begin\W*transaction\W*|begin\W*work\W*|begin\W*|commit\W*transaction\W*|commit\W*work\W*|commit\W*);';
  v_txid BIGINT;
  v_ddl_length INT;
  v_sql TEXT;
  v_cmd_count INT;
  v_match_count INT;
  v_exclude_always_match_count INT;
  v_nspname TEXT;
  v_relname TEXT;
  v_error TEXT;
  v_error_detail TEXT;
  v_context TEXT;
  v_excluded_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_exception_msg TEXT = 'Deployment exception logged in pgl_ddl_deploy.exceptions';

  --Configurable options in function setup
  c_set_config_id INT = $BUILD$||sc.id::TEXT||$BUILD$;
  -- Even though pglogical supports an array of sets, we only pipe DDL through one at a time
  -- So c_set_name is a text not text[] data type.
  c_set_name TEXT = '$BUILD$||set_name||$BUILD$';
  c_driver pgl_ddl_deploy.driver = '$BUILD$||sc.driver||$BUILD$';
  c_include_schema_regex TEXT = $BUILD$||COALESCE(''''||include_schema_regex||'''','NULL')||$BUILD$;
  c_lock_safe_deployment BOOLEAN = $BUILD$||lock_safe_deployment||$BUILD$;
  c_allow_multi_statements BOOLEAN = $BUILD$||allow_multi_statements||$BUILD$;
  c_include_only_repset_tables BOOLEAN = $BUILD$||include_only_repset_tables||$BUILD$;
  c_include_everything BOOLEAN = $BUILD$||include_everything||$BUILD$;
  c_queue_subscriber_failures BOOLEAN = $BUILD$||queue_subscriber_failures||$BUILD$;
  c_create_tags TEXT[] = '$BUILD$||create_tags::TEXT||$BUILD$';
  c_blacklisted_tags TEXT[] = '$BUILD$||blacklisted_tags::TEXT||$BUILD$';
  c_exclude_alter_table_subcommands TEXT[] = $BUILD$||COALESCE(quote_literal(exclude_alter_table_subcommands::TEXT),'NULL')||$BUILD$;
  c_signal_blocking_subscriber_sessions TEXT = $BUILD$||COALESCE(quote_literal(signal_blocking_subscriber_sessions::TEXT),'NULL')||$BUILD$;
  c_subscriber_lock_timeout INT = $BUILD$||COALESCE(subscriber_lock_timeout::TEXT,'NULL')||$BUILD$;

    --Constants based on configuration
  c_exec_prefix TEXT =(CASE
                          WHEN c_lock_safe_deployment
                          THEN 'SELECT pgl_ddl_deploy.lock_safe_executor($PGL_DDL_DEPLOY$'
                          ELSE ''
                        END);
  c_exec_suffix TEXT = (CASE
                          WHEN c_lock_safe_deployment
                          THEN '$PGL_DDL_DEPLOY$);'
                          ELSE ''
                        END);
  $BUILD$::TEXT AS declare_constants,

  $BUILD$
  --If there are any matches to our replication config, get the query
  --This will either be sent, or logged at this point if not deployable
  IF (c_include_everything AND v_exclude_always_match_count = 0) OR v_match_count > 0 THEN
        v_ddl_sql_raw = pgl_ddl_deploy.current_query();
        v_txid = txid_current();
  END IF;
  $BUILD$::TEXT AS shared_get_query,
/****
  This is the portion of the event trigger function that evaluates if SQL
  is appropriate to propagate, and does propagate the event.  It is shared
  between the normal and drop event trigger functions.
   */
  $BUILD$
        /****
          A multi-statement SQL command may fire this event trigger more than once
          This check ensures the SQL is propagated only once, if at all
         */
        IF EXISTS
           (SELECT 1 FROM pgl_ddl_deploy.events
            WHERE set_name = c_set_name
              AND txid = v_txid
              AND ddl_sql_raw = v_ddl_sql_raw
              AND pid = v_pid)
           OR EXISTS
           (SELECT 1 FROM pgl_ddl_deploy.unhandled
            WHERE set_name = c_set_name
              AND txid = v_txid
              AND ddl_sql_raw = v_ddl_sql_raw
              AND pid = v_pid)
            THEN
          RETURN;
        END IF;

        /****
          Get the command tags and reject blacklisted tags
         */
        v_sql_tags:=(SELECT pgl_ddl_deploy.sql_command_tags(v_ddl_sql_raw));
        IF (SELECT c_blacklisted_tags && v_sql_tags) THEN
          PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_config_id,
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'rejected_command_tags',
               v_txid);
          RETURN;
        /****
          If we are not allowing multi-statements at all, reject
         */
        ELSEIF (SELECT ARRAY[TG_TAG]::TEXT[] <> v_sql_tags WHERE NOT c_allow_multi_statements) THEN
          PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_config_id,
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'rejected_multi_statement',
               v_txid);
          RETURN;
        END IF;

        /****
          If this is an ALTER TABLE statement and we are excluding any subcommand tags, process now.
          Note the following.

          Because there can be more than one subcommand, we have a limited ability
          to filter out subcommands until such a time as we may have a mechanism for rebuilding only
          the SQL we want.  In other words, if we have one subcommand that we DO want (i.e. ADD COLUMN)
          and one we don't want (i.e. REFERENCES) in the same SQL, and we are "excluding" the latter,
          we can't do that exclusion safely because we WANT the ADD COLUMN statement.  In such a case,
          we are still going to allow the DDL to go through because it's better to break replication than
          miss a column addition.

          But if the only subcommand is an excluded one, i.e. ADD CONSTRAINT, then we will indeed ignore
          the DDL and the function will RETURN without executing replicate_ddl_command.
        */
        IF TG_TAG = 'ALTER TABLE' AND c_exclude_alter_table_subcommands IS NOT NULL THEN
          FOR v_cmd_rec IN
            SELECT * FROM pg_event_trigger_ddl_commands()
          LOOP
            IF pgl_ddl_deploy.get_command_type(v_cmd_rec.command) = 'alter table' THEN
              WITH subcommands AS (
                SELECT subcommand,
                  c_exclude_alter_table_subcommands && ARRAY[subcommand] AS subcommand_is_excluded,
                  MAX(CASE WHEN c_exclude_alter_table_subcommands && ARRAY[subcommand] THEN 0 ELSE 1 END) OVER() AS contains_any_valid_subcommand
                FROM unnest(pgl_ddl_deploy.get_altertable_subcmdtypes(v_cmd_rec.command)) AS subcommand
              )

              SELECT (SELECT string_agg(subcommand,', ') FROM subcommands WHERE subcommand_is_excluded),
                (SELECT contains_any_valid_subcommand FROM subcommands LIMIT 1)
               INTO v_excluded_subcommands,
                v_contains_any_valid_subcommand;
              IF v_excluded_subcommands IS NOT NULL AND v_contains_any_valid_subcommand = 0 THEN
                RAISE LOG 'Not processing DDL due to excluded subcommand(s): %: %', v_excluded_subcommands, v_ddl_sql_raw;
                RETURN;
              ELSEIF v_excluded_subcommands IS NOT NULL AND v_contains_any_valid_subcommand = 1 THEN
                RAISE WARNING $INNER_BLOCK$Filtering out more than one subcommand in one ALTER TABLE is not supported.
                Allowing to proceed: Rejected: %, SQL: %$INNER_BLOCK$, v_excluded_subcommands, v_ddl_sql_raw;
              END IF;
            END IF;
          END LOOP;
        END IF;

        v_ddl_sql_sent = v_ddl_sql_raw;

        --If there are BEGIN/COMMIT tags, attempt to strip and reparse
        IF (SELECT ARRAY['BEGIN','COMMIT']::TEXT[] && v_sql_tags) THEN
          v_ddl_sql_sent = regexp_replace(v_ddl_sql_sent, v_ddl_strip_regex, '', 'ig');

          --Sanity reparse
          PERFORM pgl_ddl_deploy.sql_command_tags(v_ddl_sql_sent);
        END IF;

        --Get provider name, in order only to run command on a subscriber to this provider
        c_provider_name:=pgl_ddl_deploy.provider_node_name(c_driver);

        /*
          Build replication DDL command which will conditionally run only on the subscriber
          In other words, this MUST be a no-op on the provider
          **Because the DDL has already run at this point (ddl_command_end)**
        */
        v_full_ddl:=$INNER_BLOCK$
        --Be sure to use provider's search_path for SQL environment consistency
            SET SEARCH_PATH TO $INNER_BLOCK$||
            CASE WHEN COALESCE(c_search_path,'') IN('','""') THEN quote_literal('') ELSE c_search_path END||$INNER_BLOCK$;

            $INNER_BLOCK$||c_exec_prefix||v_ddl_sql_sent||c_exec_suffix||$INNER_BLOCK$
            ;
        $INNER_BLOCK$;
        RAISE DEBUG 'v_full_ddl: %', v_full_ddl;
        RAISE DEBUG 'c_set_config_id: %', c_set_config_id;
        RAISE DEBUG 'c_set_name: %', c_set_name;
        RAISE DEBUG 'c_driver: %', c_driver;
        RAISE DEBUG 'v_ddl_sql_sent: %', v_ddl_sql_sent;

        v_sql:=$INNER_BLOCK$
        SELECT $BUILD$||CASE
            WHEN sc.driver = 'native'
            THEN 'pgl_ddl_deploy'
            WHEN sc.driver = 'pglogical'
            THEN 'pglogical'
            ELSE 'ERROR-EXCEPTION' END||$BUILD$.replicate_ddl_command($REPLICATE_DDL_COMMAND$
        SELECT pgl_ddl_deploy.subscriber_command
        (
          p_provider_name := $INNER_BLOCK$||COALESCE(quote_literal(c_provider_name), 'NULL')||$INNER_BLOCK$,
          p_set_name := ARRAY[$INNER_BLOCK$||quote_literal(c_set_name)||$INNER_BLOCK$],
          p_nspname := $INNER_BLOCK$||COALESCE(quote_literal(v_nspname), 'NULL')::TEXT||$INNER_BLOCK$,
          p_relname := $INNER_BLOCK$||COALESCE(quote_literal(v_relname), 'NULL')::TEXT||$INNER_BLOCK$,
          p_ddl_sql_sent := $pgl_ddl_deploy_sql$$INNER_BLOCK$||v_ddl_sql_sent||$INNER_BLOCK$$pgl_ddl_deploy_sql$,
          p_full_ddl := $pgl_ddl_deploy_sql$$INNER_BLOCK$||v_full_ddl||$INNER_BLOCK$$pgl_ddl_deploy_sql$,
          p_pid := $INNER_BLOCK$||v_pid::TEXT||$INNER_BLOCK$,
          p_set_config_id := $INNER_BLOCK$||c_set_config_id::TEXT||$INNER_BLOCK$,
          p_queue_subscriber_failures := $INNER_BLOCK$||c_queue_subscriber_failures||$INNER_BLOCK$,
          p_signal_blocking_subscriber_sessions := $INNER_BLOCK$||COALESCE(quote_literal(c_signal_blocking_subscriber_sessions),'NULL')||$INNER_BLOCK$,
          p_lock_timeout := $INNER_BLOCK$||COALESCE(c_subscriber_lock_timeout, 3000)||$INNER_BLOCK$,
          p_driver := $INNER_BLOCK$||quote_literal(c_driver)||$INNER_BLOCK$
        );
        $REPLICATE_DDL_COMMAND$,
        --Pipe this DDL command through chosen replication set
        ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']);
        $INNER_BLOCK$;
        
        RAISE DEBUG 'v_sql: %', v_sql;
        EXECUTE v_sql;

        INSERT INTO pgl_ddl_deploy.events
        (set_config_id,
         set_name,
         pid,
         executed_at,
         ddl_sql_raw,
         ddl_sql_sent,
         txid)
        VALUES
        (c_set_config_id,
         c_set_name,
         v_pid,
         current_timestamp,
         v_ddl_sql_raw,
         v_ddl_sql_sent,
         v_txid);
  $BUILD$::TEXT AS shared_deploy_logic,
  $BUILD$
  ELSEIF (v_match_count > 0 AND v_cmd_count <> v_match_count) THEN
    PERFORM pgl_ddl_deploy.log_unhandled(
     c_set_config_id,
     c_set_name,
     v_pid,
     v_ddl_sql_raw,
     TG_TAG,
     'mixed_objects',
     v_txid);
  $BUILD$::TEXT AS shared_mixed_obj_logic,

  $BUILD$
  /**
    Catch any exceptions and log in a local table
    As a safeguard, if even the exception handler fails, exit cleanly but add a server log message
  **/
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
        v_context = PG_EXCEPTION_CONTEXT,
        v_error = MESSAGE_TEXT,
        v_error_detail = PG_EXCEPTION_DETAIL;
    BEGIN
      INSERT INTO pgl_ddl_deploy.exceptions (set_config_id, set_name, pid, executed_at, ddl_sql, err_msg, err_state)
      VALUES (c_set_config_id, c_set_name, v_pid, current_timestamp, v_sql, format('%s %s %s', v_error, v_context, v_error_detail), SQLSTATE);
      RAISE WARNING '%', c_exception_msg;
    --No matter what, don't let this function block any DDL
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Unhandled exception % %', SQLERRM, SQLSTATE;
    END;
  $BUILD$::TEXT AS shared_exception_handler,

  $BUILD$
  FROM pg_namespace n
  INNER JOIN pg_class c ON n.oid = c.relnamespace
    AND c.relpersistence = 'p'
  WHERE n.nspname ~* c_include_schema_regex
    AND n.nspname !~* c_exclude_always
    AND EXISTS (SELECT 1
    FROM pg_index i
    WHERE i.indrelid = c.oid
      AND i.indisprimary)
    AND NOT EXISTS
    (SELECT 1
    FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
    WHERE rsr.name = c_set_name
      AND rsr.relid = c.oid
      AND rsr.driver = c_driver)
  $BUILD$::TEXT AS shared_repl_set_tables,

  $BUILD$
      SUM(CASE
          WHEN
          --include_schema_regex usage:
            (
              (NOT $BUILD$||include_only_repset_tables||$BUILD$) AND
              (
                (schema_name ~* c_include_schema_regex
                AND schema_name !~* c_exclude_always)
                OR
                (object_type = 'schema'
                AND object_identity ~* c_include_schema_regex
                AND object_identity !~* c_exclude_always)
              )
            )
            OR
          --include_only_repset_tables usage:
            (
              ($BUILD$||include_only_repset_tables||$BUILD$) AND
              (EXISTS
                (
                SELECT 1
                FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
                WHERE rsr.relid = c.objid
                  AND c.object_type in('table','table column','table constraint')
                  AND rsr.name = '$BUILD$||sc.set_name||$BUILD$'
                  AND rsr.driver = '$BUILD$||sc.driver||$BUILD$'
                )
              )
            )
            THEN 1
          ELSE 0 END) AS match_count,
      SUM(CASE
          WHEN
          --include_everything usage still excludes exclude_always regex:
            (
              ($BUILD$||include_everything||$BUILD$) AND
              (
                (schema_name ~* c_exclude_always)
                OR
                (object_type = 'schema'
                AND object_identity ~* c_exclude_always)
              )
            )
            THEN 1
          ELSE 0 END) AS exclude_always_match_count
  $BUILD$::TEXT AS shared_match_count
FROM pgl_ddl_deploy.rep_set_wrapper() rs
INNER JOIN pgl_ddl_deploy.set_configs sc ON sc.set_name = rs.name AND sc.driver = rs.driver 
)

, build AS (
SELECT
  id,
  set_name,
  include_schema_regex,
  include_only_repset_tables,
  include_everything,
  signal_blocking_subscriber_sessions,
  subscriber_lock_timeout,
  auto_replication_create_function_name,
  auto_replication_drop_function_name,
  auto_replication_unsupported_function_name,
  auto_replication_create_trigger_name,
  auto_replication_drop_trigger_name,
  auto_replication_unsupported_trigger_name,

CASE WHEN driver = 'pglogical' THEN '--no-op pglogical diver'::TEXT
WHEN driver = 'native' THEN $BUILD$
DO $$
BEGIN

IF NOT EXISTS (SELECT 1
FROM pg_publication_tables
WHERE pubname = '$BUILD$||set_name||$BUILD$'
AND schemaname = 'pgl_ddl_deploy'
AND tablename = 'queue') THEN
    ALTER PUBLICATION $BUILD$||quote_ident(set_name)||$BUILD$
    ADD TABLE pgl_ddl_deploy.queue;
END IF;

END$$;
$BUILD$
END AS add_queue_table_to_replication,

CASE WHEN create_tags IS NULL THEN '--no-op-null-create-tags'::TEXT ELSE
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$ || auto_replication_create_function_name || $BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

  /*****
  Only enter execution body if object being altered is relevant
   */
  SELECT COUNT(1)
    , $BUILD$||shared_match_count||$BUILD$
    , MAX(c.schema_name)
    , MAX(cl.relname)
    INTO v_cmd_count, v_match_count, v_exclude_always_match_count, v_nspname, v_relname
  FROM pg_event_trigger_ddl_commands() c
  LEFT JOIN LATERAL
    (SELECT cl.relname
     FROM pg_class cl
     WHERE cl.oid = c.objid
       AND c.classid = (SELECT oid FROM pg_class WHERE relname = 'pg_class')
    -- There should only be one table modified per event trigger
    -- At least that's the best we will do now
     LIMIT 1) cl ON TRUE;

      $BUILD$||shared_get_query||$BUILD$

  IF ((c_include_everything AND v_exclude_always_match_count = 0) OR (v_match_count > 0 AND v_cmd_count = v_match_count))
      THEN

        $BUILD$||shared_deploy_logic||$BUILD$

        INSERT INTO pgl_ddl_deploy.commands
            (set_config_id,
            set_name,
            pid,
            txid,
            classid,
            objid,
            objsubid,
            command_tag,
            object_type,
            schema_name,
            object_identity,
            in_extension)
        SELECT c_set_config_id,
            c_set_name,
            v_pid,
            v_txid,
            classid,
            objid,
            objsubid,
            command_tag,
            object_type,
            schema_name,
            object_identity,
            in_extension
        FROM pg_event_trigger_ddl_commands();

        /**
          Add table to replication set immediately, if required, and only if the set_config includes CREATE TABLE.
          We do not filter to tags here, because of possibility of multi-statement SQL.
          Optional ddl_only_replication will never auto-add tables to replication because the
          purpose is to only replicate keep the structure synchronized on the subscriber with no data.
        **/
        IF c_create_tags && '{"CREATE TABLE"}' AND NOT $BUILD$||include_only_repset_tables||$BUILD$ AND NOT $BUILD$||ddl_only_replication||$BUILD$ THEN
          PERFORM pgl_ddl_deploy.add_table_to_replication(
            p_driver:=c_driver
            ,p_set_name:=c_set_name
            ,p_relation:=c.oid
            ,p_synchronize_data:=false
          )
          $BUILD$||shared_repl_set_tables||$BUILD$;
        END IF;

  $BUILD$||shared_mixed_obj_logic||$BUILD$

  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$::TEXT
END  AS auto_replication_function,

CASE WHEN drop_tags IS NULL THEN '--no-op-null-drop-tags'::TEXT ELSE
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_drop_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

  /*****
  Only enter execution body if object being altered is relevant
   */
  SELECT COUNT(1)
    , $BUILD$||shared_match_count||$BUILD$
    , SUM(CASE
          WHEN
          --include_schema_regex usage:
            (
              (NOT $BUILD$||include_only_repset_tables||$BUILD$) AND
              (
                (schema_name !~* '^(pg_catalog|pg_toast)$'
                AND schema_name !~* c_include_schema_regex)
                OR (object_type = 'schema'
                AND object_identity !~* '^(pg_catalog|pg_toast)$'
                AND object_identity !~* c_include_schema_regex)
              )
            )
          --include_only_repset_tables cannot be used with DROP because
          --the objects no longer exist to be checked:
            THEN 1
          ELSE 0 END) AS excluded_count
    INTO v_cmd_count, v_match_count, v_exclude_always_match_count, v_excluded_count
  FROM pg_event_trigger_dropped_objects() c;

  $BUILD$||shared_get_query||$BUILD$

  IF ((c_include_everything AND v_exclude_always_match_count = 0) OR (v_match_count > 0 AND v_excluded_count = 0))

      THEN

        $BUILD$||shared_deploy_logic||$BUILD$

        INSERT INTO pgl_ddl_deploy.commands
            (set_config_id,
            set_name,
            pid,
            txid,
            classid,
            objid,
            objsubid,
            command_tag,
            object_type,
            schema_name,
            object_identity,
            in_extension)
        SELECT c_set_config_id,
            c_set_name,
            v_pid,
            v_txid,
            classid,
            objid,
            objsubid,
            TG_TAG,
            object_type,
            schema_name,
            object_identity,
            NULL
        FROM pg_event_trigger_dropped_objects();

  $BUILD$||shared_mixed_obj_logic||$BUILD$

  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
END
  AS auto_replication_drop_function,

CASE WHEN include_only_repset_tables THEN '--no-op-only-repset-tables'::TEXT ELSE
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_unsupported_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

 /*****
  Only enter execution body if object being altered is relevant
   */
  SELECT COUNT(1)
    , $BUILD$||shared_match_count||$BUILD$
    INTO v_cmd_count, v_match_count, v_exclude_always_match_count
  FROM pg_event_trigger_ddl_commands() c;

  IF ((c_include_everything AND v_exclude_always_match_count = 0) OR v_match_count > 0)
    THEN

    v_ddl_sql_raw = pgl_ddl_deploy.current_query();

    PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_config_id,
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'unsupported_command',
               v_txid);
  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
END
  AS auto_replication_unsupported_function,

CASE WHEN create_tags IS NULL THEN '--no-op-null-create-tags'::TEXT ELSE
$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_create_trigger_name||$BUILD$ ON ddl_command_end
WHEN TAG IN('$BUILD$||array_to_string(create_tags,$$','$$)||$BUILD$')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$ || auto_replication_create_function_name || $BUILD$();
$BUILD$::TEXT
END AS auto_replication_trigger,

CASE WHEN drop_tags IS NULL THEN '--no-op-null-drop-tags'::TEXT ELSE
$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ ON sql_drop
WHEN TAG IN('$BUILD$||array_to_string(drop_tags,$$','$$)||$BUILD$')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$||auto_replication_drop_function_name||$BUILD$();
$BUILD$::TEXT
END AS auto_replication_drop_trigger,

CASE WHEN include_only_repset_tables THEN '--no-op-only-repset-tables'::TEXT ELSE
$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ ON ddl_command_end
WHEN TAG IN('$BUILD$||array_to_string(pgl_ddl_deploy.unsupported_tags(),$$','$$)||$BUILD$')
EXECUTE PROCEDURE $BUILD$||auto_replication_unsupported_function_name||$BUILD$();
$BUILD$::TEXT
END AS auto_replication_unsupported_trigger,

$BUILD$
DROP TABLE IF EXISTS tmp_objs;
CREATE TEMP TABLE tmp_objs (obj_type, obj_name) AS (
VALUES
('EVENT TRIGGER','$BUILD$||auto_replication_create_trigger_name||$BUILD$'),
('EVENT TRIGGER','$BUILD$||auto_replication_drop_trigger_name||$BUILD$'),
('EVENT TRIGGER','$BUILD$||auto_replication_unsupported_trigger_name||$BUILD$'),
('FUNCTION','$BUILD$||auto_replication_create_function_name||$BUILD$()'),
('FUNCTION','$BUILD$||auto_replication_drop_function_name||$BUILD$()'),
('FUNCTION','$BUILD$||auto_replication_unsupported_function_name||$BUILD$()')
);

SELECT pgl_ddl_deploy.drop_ext_object(obj_type, obj_name)
FROM tmp_objs;
DROP EVENT TRIGGER IF EXISTS $BUILD$||auto_replication_create_trigger_name||', '||auto_replication_drop_trigger_name||', '||auto_replication_unsupported_trigger_name||$BUILD$;
DROP FUNCTION IF EXISTS $BUILD$||auto_replication_create_function_name||$BUILD$();
DROP FUNCTION IF EXISTS $BUILD$||auto_replication_drop_function_name||$BUILD$();
DROP FUNCTION IF EXISTS $BUILD$||auto_replication_unsupported_function_name||$BUILD$();
$BUILD$
    AS undeploy_sql
FROM vars)

SELECT
  b.id,
  b.set_name,
  b.include_schema_regex,
  b.include_only_repset_tables,
  b.include_everything,
  b.signal_blocking_subscriber_sessions,
  b.subscriber_lock_timeout,
  b.auto_replication_create_function_name,
  b.auto_replication_drop_function_name,
  b.auto_replication_unsupported_function_name,
  b.auto_replication_create_trigger_name,
  b.auto_replication_drop_trigger_name,
  b.auto_replication_unsupported_trigger_name,
  b.auto_replication_function,
  b.auto_replication_drop_function,
  b.auto_replication_unsupported_function,
  b.auto_replication_trigger,
  b.auto_replication_drop_trigger,
  b.auto_replication_unsupported_trigger,
  b.undeploy_sql,
  b.undeploy_sql||
  b.add_queue_table_to_replication||$BUILD$
  $BUILD$||auto_replication_function||$BUILD$
  $BUILD$||auto_replication_drop_function||$BUILD$
  $BUILD$||auto_replication_unsupported_function||$BUILD$
  $BUILD$||auto_replication_trigger||$BUILD$
  $BUILD$||auto_replication_drop_trigger||$BUILD$
  $BUILD$||auto_replication_unsupported_trigger||$BUILD$
  SELECT pgl_ddl_deploy.add_ext_object(obj_type, obj_name)
  FROM tmp_objs;
  $BUILD$ AS deploy_sql,
  $BUILD$
  ALTER EVENT TRIGGER $BUILD$||auto_replication_create_trigger_name||$BUILD$ DISABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ DISABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ DISABLE;
  $BUILD$ AS disable_sql,
  $BUILD$
  ALTER EVENT TRIGGER $BUILD$||auto_replication_create_trigger_name||$BUILD$ ENABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ ENABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ ENABLE;
  $BUILD$ AS enable_sql,
  EXISTS (SELECT 1
    FROM pg_event_trigger
    WHERE evtname IN(
        auto_replication_create_trigger_name,
        auto_replication_drop_trigger_name,
        auto_replication_unsupported_trigger_name
        )
        AND evtenabled IN('O','R','A')
    ) AS is_deployed
FROM build b;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_role(p_roleoid oid)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
/******
Assuming roles doing DDL are not superusers, this function grants needed privileges
to run through the pgl_ddl_deploy DDL deployment.
This needs to be run on BOTH provider and subscriber.
******/
DECLARE
    v_rec RECORD;
    v_sql TEXT;
    v_rsat_args TEXT;
BEGIN

    FOR v_rec IN
        SELECT quote_ident(rolname) AS rolname FROM pg_roles WHERE oid = p_roleoid
    LOOP

    v_sql:='
        GRANT USAGE ON SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
        GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.replicate_ddl_command(text, text[]) TO '||v_rec.rolname||';
        GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.add_table_to_replication(pgl_ddl_deploy.driver, name, regclass, boolean) TO '||v_rec.rolname||';
        GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.notify_subscription_refresh(name, boolean) TO '||v_rec.rolname||';
        GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) TO '||v_rec.rolname||';
        GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, name, name) TO '||v_rec.rolname||';
        GRANT INSERT, UPDATE, SELECT ON ALL TABLES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';';
    EXECUTE v_sql;

    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
        v_rsat_args:=pg_get_function_identity_arguments('pglogical.replication_set_add_table'::REGPROC);


        v_sql:='
        GRANT USAGE ON SCHEMA pglogical TO '||v_rec.rolname||';
        GRANT EXECUTE ON FUNCTION pglogical.replicate_ddl_command(text, text[]) TO '||v_rec.rolname||';
        GRANT EXECUTE ON FUNCTION pglogical.replication_set_add_table(' || v_rsat_args || ') TO '||v_rec.rolname||';
        GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO '||v_rec.rolname||';';
        EXECUTE v_sql;
    END IF; 

    RETURN true;
    END LOOP;
RETURN false;
END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.override() RETURNS BOOLEAN AS $BODY$
BEGIN
RETURN FALSE;
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;


-- Now re-deploy event triggers and functions
SELECT id, pgl_ddl_deploy.deploy(id) AS deployed
FROM ddl_deploy_to_refresh;

DROP TABLE IF EXISTS ddl_deploy_to_refresh;
DROP TABLE IF EXISTS tmp_objs;

-- Ensure added roles have write permissions for new tables added
-- Not so easy to pre-package this with default privileges because
-- we can't assume everyone uses the same role to deploy this extension
SELECT pgl_ddl_deploy.add_role(role_oid)
FROM (
SELECT DISTINCT r.oid AS role_oid
FROM information_schema.table_privileges tp
INNER JOIN pg_roles r ON r.rolname = tp.grantee AND NOT r.rolsuper
WHERE table_schema = 'pgl_ddl_deploy'
  AND privilege_type = 'INSERT'
  AND table_name = 'subscriber_logs'
) roles_with_existing_privileges;

REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.add_table_to_replication(pgl_ddl_deploy.driver, name, regclass, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.notify_subscription_refresh(name, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, name, name) FROM PUBLIC;


