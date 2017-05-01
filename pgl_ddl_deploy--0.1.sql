-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

CREATE SCHEMA pgl_ddl_deploy;

CREATE TABLE pgl_ddl_deploy.set_config (
    set_name NAME PRIMARY KEY,
    include_schema_regex TEXT,
    lock_safe_deployment BOOLEAN DEFAULT TRUE,
    pass_mixed_ddl BOOLEAN DEFAULT FALSE
    );

CREATE TABLE pgl_ddl_deploy.events (
    id SERIAL PRIMARY KEY,
    set_name NAME,
    pid INT,
    executed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    ddl_sql TEXT,
    backend_xmin BIGINT,
    CONSTRAINT unique_pid_xmin_sql UNIQUE (set_name, pid, backend_xmin, ddl_sql));

CREATE TABLE pgl_ddl_deploy.exceptions (
    id SERIAL PRIMARY KEY,
    set_name NAME,
    pid INT,
    executed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    ddl_sql TEXT,
    err_msg TEXT,
    err_state TEXT);

CREATE TABLE pgl_ddl_deploy.unhandled (
    id SERIAL PRIMARY KEY,
    set_name NAME,
    pid INT,
    executed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    ddl_sql TEXT,
    lock_count INT,
    too_long BOOLEAN,
    mixed BOOLEAN);

CREATE TABLE pgl_ddl_deploy.subscriber_logs (
    id SERIAL PRIMARY KEY,
    set_name NAME,
    provider_pid INT,
    subscriber_pid INT,
    executed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    ddl_sql TEXT);

CREATE TABLE pgl_ddl_deploy.commands (
    id SERIAL PRIMARY KEY,
    set_name NAME,
    pid INT,
    backend_xmin BIGINT,
    classid Oid,
    objid Oid,
    objsubid integer,
    command_tag text,
    object_type text,
    schema_name text,
    object_identity text,
    in_extension bool);

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.lock_safe_executor(p_sql TEXT)
RETURNS VOID AS $BODY$
BEGIN
SET lock_timeout TO '1ms';
LOOP
  BEGIN
    EXECUTE p_sql;
    EXIT;
  EXCEPTION
    WHEN lock_not_available
      THEN RAISE WARNING 'Could not obtain immediate lock for SQL %, retrying', p_sql;
      PERFORM pg_sleep(3);
    WHEN OTHERS THEN
      RAISE;
  END;
END LOOP;
END;
$BODY$
LANGUAGE plpgsql;

CREATE VIEW pgl_ddl_deploy.event_trigger_schema AS
WITH vars AS
(SELECT set_name,

  'pgl_ddl_deploy.auto_replicate_ddl_'||set_name AS auto_replication_function_name,
  'pgl_ddl_deploy.auto_replicate_ddl_drop_'||set_name AS auto_replication_drop_function_name,
  'auto_replicate_ddl_'||set_name AS auto_replication_trigger_name,
  'auto_replicate_ddl_drop_'||set_name AS auto_replication_drop_trigger_name,

  /****
  These constants in DECLARE portion of all functions is identical and can be shared
   */
  $BUILD$
  c_search_path TEXT = (SELECT current_setting('search_path'));
  --The actual max number of allowed characters is track_activity_query_size - 1 character
  c_max_query_length INT = (SELECT current_setting('track_activity_query_size')::INT) - 1;
  c_provider_name TEXT;
   --TODO: How do I decide which replication set we care about?
  v_pid INT = pg_backend_pid();
  v_rec RECORD;
  v_ddl TEXT;
  v_backend_xmin BIGINT;
  v_already_executed BOOLEAN;
  v_ddl_length INT;
  v_sql TEXT;
  v_cmd_count INT;
  v_match_count INT;
  v_excluded_count INT;
  c_exclude_always TEXT = '^(pg_catalog|information_schema|pg_temp|pg_toast|pgl_ddl_deploy|pglogical).*';

  --Configurable options in function setup
  c_set_name TEXT = '$BUILD$||set_name||$BUILD$';
  c_include_schema_regex TEXT = '$BUILD$||include_schema_regex||$BUILD$';
  c_lock_safe_deployment BOOLEAN = $BUILD$||lock_safe_deployment||$BUILD$;
  c_pass_mixed_ddl BOOLEAN = $BUILD$||pass_mixed_ddl||$BUILD$;

    --Constants based on configuration
  c_exec_prefix TEXT =(CASE
                          WHEN c_lock_safe_deployment
                          THEN 'PERFORM pgl_ddl_deploy.lock_safe_executor($PGL_DDL_DEPLOY$'
                          ELSE ''
                        END);
  c_exec_suffix TEXT = (CASE
                          WHEN c_lock_safe_deployment
                          THEN '$PGL_DDL_DEPLOY$)'
                          ELSE ''
                        END);
  $BUILD$ AS declare_constants
FROM pglogical.replication_set rs
INNER JOIN pgl_ddl_deploy.set_config sc USING (set_name))

, build AS (
SELECT set_name,
  auto_replication_function_name,
  auto_replication_drop_function_name,
  auto_replication_trigger_name,
  auto_replication_drop_trigger_name,
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

  /*****
  Only enter execution body if table being altered is in a relevant schema
   */
  SELECT COUNT(1)
    , SUM(CASE
          WHEN schema_name ~* c_include_schema_regex
            AND schema_name !~* c_exclude_always
            OR (object_type = 'schema'
              AND object_identity ~* c_include_schema_regex)
            THEN 1
          ELSE 0 END) AS relevant_schema_count
    INTO v_cmd_count, v_match_count
  FROM pg_event_trigger_ddl_commands()
  WHERE
    schema_name ~* c_include_schema_regex
    AND schema_name !~* c_exclude_always
    OR (object_type = 'schema'
      AND object_identity ~* c_include_schema_regex);

  IF (v_match_count > 0 AND c_pass_mixed_ddl) OR
     (v_match_count > 0 AND v_cmd_count = v_match_count)
      THEN

        --Fresh snapshot for pg_stat_activity
        PERFORM pg_stat_clear_snapshot();

        SELECT query, backend_xmin
        INTO v_ddl, v_backend_xmin
        FROM pg_stat_activity WHERE pid = v_pid;

        /****
        A multi-statement SQL command may fire this event trigger more than once
        This check ensures the SQL is propagated only once, if at all
         */
        v_already_executed:=(SELECT EXISTS
                             (SELECT 1 FROM pgl_ddl_deploy.events
                              WHERE set_name = c_set_name
                                AND backend_xmin = v_backend_xmin
                                AND ddl_sql = v_ddl
                                AND pid = v_pid));

        IF NOT v_already_executed THEN
          v_ddl_length:=LENGTH(v_ddl);

          --Get provider name, in order only to run command on a subscriber to this provider
          c_provider_name:=(SELECT n.node_name FROM pglogical.node n INNER JOIN pglogical.local_node ln USING (node_id));

          IF v_ddl_length < c_max_query_length THEN

            /*
              Build replication DDL command which will conditionally run only on the subscriber
              In other words, this MUST be a no-op on the provider
              **Because the DDL has already run at this point (ddl_command_end)**
            */
            v_sql:=$INNER_BLOCK$
            SELECT pglogical.replicate_ddl_command($REPLICATE_DDL_COMMAND$
            DO $AUTO_REPLICATE_BLOCK$
            BEGIN

            --Only run on subscriber with this replication set, and matching provider node name
            IF EXISTS (SELECT 1
                      FROM pglogical.subscription s
                      INNER JOIN pglogical.node n
                        ON n.node_id = s.sub_origin
                        AND n.node_name = '$INNER_BLOCK$||c_provider_name||$INNER_BLOCK$'
                      WHERE sub_replication_sets && ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']) THEN

              --Be sure to use provider's search_path for SQL environment consistency
              SET SEARCH_PATH TO $INNER_BLOCK$||c_search_path||$INNER_BLOCK$;

              --Execute DDL
              $INNER_BLOCK$||c_exec_prefix||v_ddl||c_exec_suffix||$INNER_BLOCK$
              ;

              --Log change on subscriber
              INSERT INTO pgl_ddl_deploy.subscriber_logs
              (set_name,
               provider_pid,
               subscriber_pid,
               executed_at,
               ddl_sql)
              VALUES
              ('$INNER_BLOCK$||c_set_name||$INNER_BLOCK$',
              $INNER_BLOCK$||v_pid::TEXT||$INNER_BLOCK$,
               pg_backend_pid(),
               current_timestamp,
               $SQL$$INNER_BLOCK$||v_ddl||$INNER_BLOCK$$SQL$);

            END IF;

            END$AUTO_REPLICATE_BLOCK$;
            $REPLICATE_DDL_COMMAND$,
            --Pipe this DDL command through chosen replication set
            ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']);
            $INNER_BLOCK$;

            RAISE DEBUG '%', v_sql;
            EXECUTE v_sql;

            INSERT INTO pgl_ddl_deploy.events
            (set_name,
             pid,
             executed_at,
             ddl_sql,
             backend_xmin)
            VALUES
            (c_set_name,
             v_pid,
             current_timestamp,
             v_ddl,
             v_backend_xmin);

            INSERT INTO pgl_ddl_deploy.commands
                (set_name,
                pid,
                backend_xmin,
                classid,
                objid,
                objsubid,
                command_tag,
                object_type,
                schema_name,
                object_identity,
                in_extension)
            SELECT c_set_name,
                v_pid,
                v_backend_xmin,
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
            Add table to replication set immediately, if required.
            We do not filter to tags here, because of possibility of multi-statement SQL
            **/
            PERFORM pglogical.replication_set_add_table(
              set_name:=c_set_name
              ,relation:=c.relid
              ,synchronize_data:=false
            )
            FROM pg_stat_user_tables c
            WHERE c.schemaname ~* c_include_schema_regex
              AND c.schemaname !~* c_exclude_always
              AND EXISTS (SELECT 1
              FROM pg_index i
              WHERE i.indrelid = c.relid
                AND i.indisprimary)
              AND NOT EXISTS
              (SELECT 1
              FROM pglogical.replication_set_relation rsr
              INNER JOIN pglogical.replication_set r
                ON r.set_id = rsr.set_id
              WHERE r.set_name = c_set_name
                AND rsr.set_reloid = c.relid);

          ELSE

            INSERT INTO pgl_ddl_deploy.unhandled
              (set_name,
               pid,
               executed_at,
               ddl_sql,
               too_long)
              VALUES
              (c_set_name,
               v_pid,
               current_timestamp,
               v_ddl,
               /****
                It shouldn't be possible for v_ddl_length to be greater
                than c_max_query_length, but it doesn't hurt.
                */
               (v_ddl_length >= c_max_query_length));
            RAISE WARNING 'Unhandled deployment logged in pgl_ddl_deploy.unhandled at %', current_timestamp;
        END IF;

      END IF;
  ELSEIF (v_match_count > 0 AND v_cmd_count <> v_match_count) THEN
    INSERT INTO pgl_ddl_deploy.unhandled
    (set_name,
     pid,
     executed_at,
     ddl_sql,
     mixed)
    VALUES
    (c_set_name,
     v_pid,
     current_timestamp,
     v_ddl,
     TRUE);
    RAISE WARNING 'Unhandled deployment logged in pgl_ddl_deploy.unhandled at %', current_timestamp;
  END IF;

/**
  Catch any exceptions and log in a local table
  As a safeguard, if even the exception handler fails, exit cleanly but add a server log message
**/
EXCEPTION WHEN OTHERS THEN
  BEGIN
    INSERT INTO pgl_ddl_deploy.exceptions (set_name, pid, executed_at, ddl_sql, err_msg, err_state)
    VALUES (c_set_name, v_pid, current_timestamp, v_sql, SQLERRM, SQLSTATE);
    RAISE WARNING 'Deployment exception logged in pgl_ddl_deploy.exceptions at %', current_timestamp;
  --No matter what, don't let this function block any DDL
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Unhandled exception % %', SQLERRM, SQLSTATE;
  END;
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
  AS auto_replication_function,

$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_drop_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

  /*****
  Only enter execution body if table being altered is in a relevant schema
   */
  SELECT COUNT(1)
    , SUM(CASE
          WHEN schema_name ~* c_include_schema_regex
            AND schema_name !~* c_exclude_always
            OR (object_type = 'schema'
              AND object_identity ~* c_include_schema_regex)
            THEN 1
          ELSE 0 END) AS relevant_schema_count
    , SUM(CASE
          WHEN (schema_name !~* '^(pg_catalog|pg_toast)$'
            AND schema_name !~* c_include_schema_regex)
            OR (object_type = 'schema'
              AND object_identity !~* '^(pg_catalog|pg_toast)$'
              AND object_identity !~* c_include_schema_regex)
            THEN 1
          ELSE 0 END) AS excluded_schema_count
    INTO v_cmd_count, v_match_count, v_excluded_count
  FROM pg_event_trigger_dropped_objects()
  WHERE
    schema_name ~* c_include_schema_regex
    AND schema_name !~* c_exclude_always
    OR (object_type = 'schema'
      AND object_identity ~* c_include_schema_regex);

  IF (v_match_count > 0 AND c_pass_mixed_ddl) OR
     (v_match_count > 0 AND v_excluded_count = 0)

      THEN

        --Fresh snapshot for pg_stat_activity
        PERFORM pg_stat_clear_snapshot();

        SELECT query, backend_xmin
        INTO v_ddl, v_backend_xmin
        FROM pg_stat_activity WHERE pid = v_pid;

        /****
        A multi-statement SQL command may fire this event trigger more than once
        This check ensures the SQL is propagated only once, if at all
         */
        v_already_executed:=(SELECT EXISTS
                             (SELECT 1 FROM pgl_ddl_deploy.events
                              WHERE set_name = c_set_name
                                AND backend_xmin = v_backend_xmin
                                AND ddl_sql = v_ddl
                                AND pid = v_pid));

        IF NOT v_already_executed THEN
          v_ddl_length:=LENGTH(v_ddl);

          --Get provider name, in order only to run command on a subscriber to this provider
          c_provider_name:=(SELECT n.node_name FROM pglogical.node n INNER JOIN pglogical.local_node ln USING (node_id));

          IF v_ddl_length < c_max_query_length THEN

            /*
              Build replication DDL command which will conditionally run only on the subscriber
              In other words, this MUST be a no-op on the provider
              **Because the DDL has already run at this point (ddl_command_end)**
            */
            v_sql:=$INNER_BLOCK$
            SELECT pglogical.replicate_ddl_command($REPLICATE_DDL_COMMAND$
            DO $AUTO_REPLICATE_BLOCK$
            BEGIN

            --Only run on subscriber with this replication set, and matching provider node name
            IF EXISTS (SELECT 1
                      FROM pglogical.subscription s
                      INNER JOIN pglogical.node n
                        ON n.node_id = s.sub_origin
                        AND n.node_name = '$INNER_BLOCK$||c_provider_name||$INNER_BLOCK$'
                      WHERE sub_replication_sets && ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']) THEN

              --Be sure to use provider's search_path for SQL environment consistency
              SET SEARCH_PATH TO $INNER_BLOCK$||c_search_path||$INNER_BLOCK$;

              --Execute DDL
              $INNER_BLOCK$||c_exec_prefix||v_ddl||c_exec_suffix||$INNER_BLOCK$
              ;

              --Log change on subscriber
              INSERT INTO pgl_ddl_deploy.subscriber_logs
              (set_name,
               provider_pid,
               subscriber_pid,
               executed_at,
               ddl_sql)
              VALUES
              ('$INNER_BLOCK$||c_set_name||$INNER_BLOCK$',
              $INNER_BLOCK$||v_pid::TEXT||$INNER_BLOCK$,
               pg_backend_pid(),
               current_timestamp,
               $SQL$$INNER_BLOCK$||v_ddl||$INNER_BLOCK$$SQL$);

            END IF;

            END$AUTO_REPLICATE_BLOCK$;
            $REPLICATE_DDL_COMMAND$,
            --Pipe this DDL command through chosen replication set
            ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']);
            $INNER_BLOCK$;

            RAISE DEBUG '%', v_sql;
            EXECUTE v_sql;

            INSERT INTO pgl_ddl_deploy.events
            (set_name,
             pid,
             executed_at,
             ddl_sql,
             backend_xmin)
            VALUES
            (c_set_name,
             v_pid,
             current_timestamp,
             v_ddl,
             v_backend_xmin);

            INSERT INTO pgl_ddl_deploy.commands
                (set_name,
                pid,
                backend_xmin,
                classid,
                objid,
                objsubid,
                command_tag,
                object_type,
                schema_name,
                object_identity,
                in_extension)
            SELECT c_set_name,
                v_pid,
                v_backend_xmin,
                classid,
                objid,
                objsubid,
                TG_TAG,
                object_type,
                schema_name,
                object_identity,
                NULL
            FROM pg_event_trigger_dropped_objects();

          ELSE

            INSERT INTO pgl_ddl_deploy.unhandled
              (set_name,
               pid,
               executed_at,
               ddl_sql,
               too_long)
              VALUES
              (c_set_name,
               v_pid,
               current_timestamp,
               v_ddl,
               /****
                It shouldn't be possible for v_ddl_length to be greater
                than c_max_query_length, but it doesn't hurt.
                */
               (v_ddl_length >= c_max_query_length));
                RAISE WARNING 'Unhandled deployment logged in pgl_ddl_deploy.unhandled at %', current_timestamp;
        END IF;

      END IF;
  ELSEIF (v_match_count > 0 AND v_cmd_count <> v_match_count) THEN
    INSERT INTO pgl_ddl_deploy.unhandled
    (set_name,
     pid,
     executed_at,
     ddl_sql,
     mixed)
    VALUES
    (c_set_name,
     v_pid,
     current_timestamp,
     v_ddl,
     TRUE);
    RAISE WARNING 'Unhandled deployment logged in pgl_ddl_deploy.unhandled at %', current_timestamp;

  END IF;

/**
  Catch any exceptions and log in a local table
  As a safeguard, if even the exception handler fails, exit cleanly but add a server log message
**/
EXCEPTION WHEN OTHERS THEN
  BEGIN
    INSERT INTO pgl_ddl_deploy.exceptions (set_name, pid, executed_at, ddl_sql, err_msg, err_state)
    VALUES (c_set_name, v_pid, current_timestamp, v_sql, SQLERRM, SQLSTATE);
    RAISE WARNING 'Deployment exception logged in pgl_ddl_deploy.exceptions at %', current_timestamp;
  --No matter what, don't let this function block any DDL
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Unhandled exception % %', SQLERRM, SQLSTATE;
  END;
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
  AS auto_replication_drop_function,

$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_trigger_name||$BUILD$ ON ddl_command_end
WHEN TAG IN(
  'ALTER TABLE'
  ,'CREATE SEQUENCE'
  ,'ALTER SEQUENCE'
  ,'CREATE SCHEMA'
  ,'CREATE TABLE'
  ,'CREATE TABLE AS'
  ,'SELECT INTO'
  ,'CREATE FUNCTION'
  ,'ALTER FUNCTION'
  ,'CREATE TYPE'
  ,'ALTER TYPE'
  ,'CREATE VIEW'
  ,'ALTER VIEW')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$||auto_replication_function_name||$BUILD$();
$BUILD$ AS auto_replication_trigger,

$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ ON sql_drop
WHEN TAG IN(
  'DROP SCHEMA'
  ,'DROP TABLE'
  ,'DROP FUNCTION'
  ,'DROP TYPE'
  ,'DROP VIEW')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$||auto_replication_drop_function_name||$BUILD$();
$BUILD$ AS auto_replication_drop_trigger
FROM vars)

SELECT b.set_name,
  b.auto_replication_function_name,
  b.auto_replication_drop_function_name,
  b.auto_replication_trigger_name,
  b.auto_replication_drop_trigger_name,
  b.auto_replication_function,
  b.auto_replication_drop_function,
  b.auto_replication_trigger,
  b.auto_replication_drop_trigger,
  $BUILD$
  DROP EVENT TRIGGER IF EXISTS $BUILD$||auto_replication_trigger_name||', '||auto_replication_drop_trigger_name||$BUILD$;
  DROP FUNCTION IF EXISTS $BUILD$||auto_replication_function_name||$BUILD$();
  DROP FUNCTION IF EXISTS $BUILD$||auto_replication_drop_function_name||$BUILD$();
  $BUILD$||auto_replication_function||$BUILD$
  $BUILD$||auto_replication_drop_function||$BUILD$
  $BUILD$||auto_replication_trigger||$BUILD$
  $BUILD$||auto_replication_drop_trigger||$BUILD$
  $BUILD$ AS deploy_sql
FROM build b;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deploy(p_set_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_sql TEXT = (SELECT deploy_sql
                FROM pgl_ddl_deploy.event_trigger_schema
                WHERE set_name = p_set_name);
BEGIN
  IF v_sql IS NULL THEN
    RETURN FALSE;
  ELSE
    EXECUTE v_sql;
    RETURN TRUE;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;
