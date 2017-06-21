-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

CREATE FUNCTION pgl_ddl_deploy.sql_command_tags(p_sql TEXT)
RETURNS TEXT[] AS
'MODULE_PATHNAME', 'sql_command_tags'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION pgl_ddl_deploy.exclude_regex()
RETURNS TEXT AS
$BODY$
SELECT '^(pg_catalog|information_schema|pg_temp|pg_toast|pgl_ddl_deploy|pglogical).*'::TEXT;
$BODY$
LANGUAGE SQL IMMUTABLE;

CREATE FUNCTION pgl_ddl_deploy.blacklisted_tags()
RETURNS TEXT[] AS
$BODY$
SELECT '{
        INSERT,
        UPDATE,
        DELETE,
        TRUNCATE,
        SELECT,
        ROLLBACK,
        "CREATE EXTENSION",
        "ALTER EXTENSION",
        "DROP EXTENSION"}'::TEXT[];
$BODY$
LANGUAGE SQL IMMUTABLE;

CREATE TABLE pgl_ddl_deploy.set_configs (
    set_name NAME PRIMARY KEY,
    include_schema_regex TEXT NOT NULL,
    lock_safe_deployment BOOLEAN DEFAULT FALSE NOT NULL,
    allow_multi_statements BOOLEAN DEFAULT TRUE NOT NULL,
    CONSTRAINT valid_regex CHECK (CASE WHEN regexp_replace('',include_schema_regex,'') = '' THEN TRUE ELSE FALSE END)
    );

SELECT pg_catalog.pg_extension_config_dump('pgl_ddl_deploy.set_configs', '');

CREATE TABLE pgl_ddl_deploy.events (
    id SERIAL PRIMARY KEY,
    set_name NAME,
    pid INT,
    executed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    ddl_sql_raw TEXT,
    ddl_sql_sent TEXT,
    backend_xmin BIGINT
    );

CREATE UNIQUE INDEX ON pgl_ddl_deploy.events (set_name, pid, backend_xmin, md5(ddl_sql_raw));

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
    ddl_sql_raw TEXT,
    command_tag TEXT,
    reason TEXT,
    backend_xmin BIGINT,
    CONSTRAINT valid_reason CHECK (reason IN('mixed_objects','rejected_command_tags','rejected_multi_statement','too_long','unsupported_command'))
    );

CREATE UNIQUE INDEX ON pgl_ddl_deploy.unhandled (set_name, pid, backend_xmin, md5(ddl_sql_raw));

CREATE FUNCTION pgl_ddl_deploy.log_unhandled
(p_set_name TEXT,
 p_pid INT,
 p_ddl_sql_raw TEXT,
 p_command_tag TEXT,
 p_reason TEXT,
 p_backend_xmin BIGINT)
RETURNS VOID AS
$BODY$
DECLARE
    c_unhandled_msg TEXT = 'Unhandled deployment logged in pgl_ddl_deploy.unhandled';
BEGIN
INSERT INTO pgl_ddl_deploy.unhandled
  (set_name,
   pid,
   executed_at,
   ddl_sql_raw,
   command_tag,
   reason,
   backend_xmin)
VALUES
  (p_set_name,
   p_pid,
   current_timestamp,
   p_ddl_sql_raw,
   p_command_tag,
   p_reason,
   p_backend_xmin);
RAISE WARNING '%', c_unhandled_msg;
END;
$BODY$
LANGUAGE plpgsql;

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

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.stat_activity()
RETURNS TABLE (query TEXT, backend_xmin XID)
AS
$BODY$
SELECT query, backend_xmin
FROM pg_stat_activity
WHERE pid = pg_backend_pid();
$BODY$
SECURITY DEFINER
LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.lock_safe_executor(p_sql TEXT)
RETURNS VOID AS $BODY$
BEGIN
SET lock_timeout TO '10ms';
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

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_ext_object
  (p_type text -- 'EVENT TRIGGER' OR 'FUNCTION'
  , p_full_obj_name text)
RETURNS VOID AS
$BODY$
BEGIN
PERFORM pgl_ddl_deploy.toggle_ext_object(p_type, p_full_obj_name, 'ADD');
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.drop_ext_object
  (p_type text -- 'EVENT TRIGGER' OR 'FUNCTION'
  , p_full_obj_name text)
RETURNS VOID AS
$BODY$
BEGIN
PERFORM pgl_ddl_deploy.toggle_ext_object(p_type, p_full_obj_name, 'DROP');
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.toggle_ext_object
  (p_type text -- 'EVENT TRIGGER' OR 'FUNCTION'
  , p_full_obj_name text
  , p_toggle text)
RETURNS VOID AS
$BODY$
DECLARE
  c_valid_types TEXT[] = ARRAY['EVENT TRIGGER','FUNCTION'];
  c_valid_toggles TEXT[] = ARRAY['ADD','DROP'];
BEGIN

IF NOT (SELECT ARRAY[p_type] && c_valid_types) THEN
  RAISE EXCEPTION 'Must pass one of % as 1st arg.', array_to_string(c_valid_types);
END IF;

IF NOT (SELECT ARRAY[p_toggle] && c_valid_toggles) THEN
  RAISE EXCEPTION 'Must pass one of % as 3rd arg.', array_to_string(c_valid_toggles);
END IF;

EXECUTE 'ALTER EXTENSION pgl_ddl_deploy '||p_toggle||' '||p_type||' '||p_full_obj_name;

EXCEPTION
  WHEN undefined_function THEN
    RETURN;
  WHEN undefined_object THEN
    RETURN;
  WHEN object_not_in_prerequisite_state THEN
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;

CREATE VIEW pgl_ddl_deploy.event_trigger_schema AS
WITH vars AS
(SELECT set_name,

  'pgl_ddl_deploy.auto_replicate_ddl_'||set_name AS auto_replication_function_name,
  'pgl_ddl_deploy.auto_replicate_ddl_drop_'||set_name AS auto_replication_drop_function_name,
  'pgl_ddl_deploy.auto_replicate_ddl_unsupported_'||set_name AS auto_replication_unsupported_function_name,
  'auto_replicate_ddl_'||set_name AS auto_replication_trigger_name,
  'auto_replicate_ddl_drop_'||set_name AS auto_replication_drop_trigger_name,
  'auto_replicate_ddl_unsupported_'||set_name AS auto_replication_unsupported_trigger_name,
  include_schema_regex,

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
  v_ddl_sql_raw TEXT;
  v_ddl_sql_sent TEXT;
  v_sql_tags TEXT[];

  /*****
  We need to strip the DDL of:
    1. Transaction begin and commit, which cannot run inside plpgsql
  *****/
  v_ddl_strip_regex TEXT = '(begin\W*transaction\W*|begin\W*work\W*|begin\W*|commit\W*transaction\W*|commit\W*work\W*|commit\W*);';
  v_backend_xmin BIGINT;
  v_ddl_length INT;
  v_sql TEXT;
  v_cmd_count INT;
  v_match_count INT;
  v_excluded_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_exception_msg TEXT = 'Deployment exception logged in pgl_ddl_deploy.exceptions';

  --Configurable options in function setup
  c_set_name TEXT = '$BUILD$||set_name||$BUILD$';
  c_include_schema_regex TEXT = '$BUILD$||include_schema_regex||$BUILD$';
  c_lock_safe_deployment BOOLEAN = $BUILD$||lock_safe_deployment||$BUILD$;
  c_allow_multi_statements BOOLEAN = $BUILD$||allow_multi_statements||$BUILD$;

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
  IF v_match_count > 0 THEN
    --Fresh snapshot for pg_stat_activity
        PERFORM pg_stat_clear_snapshot();

        SELECT query, backend_xmin
        INTO v_ddl_sql_raw, v_backend_xmin
        FROM pgl_ddl_deploy.stat_activity();
  END IF;
  $BUILD$::TEXT AS shared_get_query,
/****
  This is the portion of the event trigger function that evaluates if SQL
  is appropriate to propagate, and does propagate the event.  It is shared
  between the normal and drop event trigger functions.
   */
  $BUILD$
        /****
          Length must be checked against max length allowed for pg_stat_activity.
          Bail if length equals max.
          Strictly speaking, this allows edge cases, but we will tolerate that.
          */
        v_ddl_length:=LENGTH(v_ddl_sql_raw);
        IF v_ddl_length = c_max_query_length THEN
          PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'too_long',
               v_backend_xmin);
          RETURN;
        END IF;

        /****
          A multi-statement SQL command may fire this event trigger more than once
          This check ensures the SQL is propagated only once, if at all
         */
        IF EXISTS
           (SELECT 1 FROM pgl_ddl_deploy.events
            WHERE set_name = c_set_name
              AND backend_xmin = v_backend_xmin
              AND ddl_sql_raw = v_ddl_sql_raw
              AND pid = v_pid)
           OR EXISTS
           (SELECT 1 FROM pgl_ddl_deploy.unhandled
            WHERE set_name = c_set_name
              AND backend_xmin = v_backend_xmin
              AND ddl_sql_raw = v_ddl_sql_raw
              AND pid = v_pid)
            THEN
          RETURN;
        END IF;

        /****
          Get the command tags and reject blacklisted tags
         */
        v_sql_tags:=(SELECT pgl_ddl_deploy.sql_command_tags(v_ddl_sql_raw));
        IF (SELECT pgl_ddl_deploy.blacklisted_tags() && v_sql_tags) THEN
          PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'rejected_command_tags',
               v_backend_xmin);
          RETURN;
        /****
          If we are not allowing multi-statements at all, reject
         */
        ELSEIF (SELECT ARRAY[TG_TAG]::TEXT[] <> v_sql_tags WHERE NOT c_allow_multi_statements) THEN
          PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'rejected_multi_statement',
               v_backend_xmin);
          RETURN;
        END IF;

        v_ddl_sql_sent = v_ddl_sql_raw;

        --If there are BEGIN/COMMIT tags, attempt to strip and reparse
        IF (SELECT ARRAY['BEGIN','COMMIT']::TEXT[] && v_sql_tags) THEN
          v_ddl_sql_sent = regexp_replace(v_ddl_sql_sent, v_ddl_strip_regex, '', 'ig');

          --Sanity reparse
          PERFORM pgl_ddl_deploy.sql_command_tags(v_ddl_sql_sent);
        END IF;

        --Get provider name, in order only to run command on a subscriber to this provider
        c_provider_name:=(SELECT n.node_name FROM pglogical.node n INNER JOIN pglogical.local_node ln USING (node_id));

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

            --Execute DDL - the reason we use execute here is partly to handle no trailing semicolon
            EXECUTE $EXEC_SUBSCRIBER$
            $INNER_BLOCK$||c_exec_prefix||v_ddl_sql_sent||c_exec_suffix||$INNER_BLOCK$
            $EXEC_SUBSCRIBER$;

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
             $SQL$$INNER_BLOCK$||v_ddl_sql_sent||$INNER_BLOCK$$SQL$);

        END IF;

        END$AUTO_REPLICATE_BLOCK$;
        $REPLICATE_DDL_COMMAND$,
        --Pipe this DDL command through chosen replication set
        ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']);
        $INNER_BLOCK$;

        EXECUTE v_sql;

        INSERT INTO pgl_ddl_deploy.events
        (set_name,
         pid,
         executed_at,
         ddl_sql_raw,
         ddl_sql_sent,
         backend_xmin)
        VALUES
        (c_set_name,
         v_pid,
         current_timestamp,
         v_ddl_sql_raw,
         v_ddl_sql_sent,
         v_backend_xmin);
  $BUILD$::TEXT AS shared_deploy_logic,
  $BUILD$
  ELSEIF (v_match_count > 0 AND v_cmd_count <> v_match_count) THEN
    PERFORM pgl_ddl_deploy.log_unhandled(
     c_set_name,
     v_pid,
     v_ddl_sql_raw,
     TG_TAG,
     'mixed_objects',
     v_backend_xmin);
  $BUILD$::TEXT AS shared_mixed_obj_logic,

  $BUILD$
  /**
    Catch any exceptions and log in a local table
    As a safeguard, if even the exception handler fails, exit cleanly but add a server log message
  **/
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      INSERT INTO pgl_ddl_deploy.exceptions (set_name, pid, executed_at, ddl_sql, err_msg, err_state)
      VALUES (c_set_name, v_pid, current_timestamp, v_sql, SQLERRM, SQLSTATE);
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
    FROM pglogical.replication_set_relation rsr
    INNER JOIN pglogical.replication_set r
      ON r.set_id = rsr.set_id
    WHERE r.set_name = c_set_name
      AND rsr.set_reloid = c.oid)
  $BUILD$::TEXT AS shared_repl_set_tables,
  $BUILD$
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
  FROM pg_event_trigger_ddl_commands();
  $BUILD$::TEXT AS shared_objects_check
FROM pglogical.replication_set rs
INNER JOIN pgl_ddl_deploy.set_configs sc USING (set_name)
)

, build AS (
SELECT set_name,
  auto_replication_function_name,
  auto_replication_drop_function_name,
  auto_replication_unsupported_function_name,
  auto_replication_trigger_name,
  auto_replication_drop_trigger_name,
  auto_replication_unsupported_trigger_name,
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

  $BUILD$||shared_objects_check||$BUILD$

  $BUILD$||shared_get_query||$BUILD$

  IF (v_match_count > 0 AND v_cmd_count = v_match_count)
      THEN

        $BUILD$||shared_deploy_logic||$BUILD$

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
          ,relation:=c.oid
          ,synchronize_data:=false
        )
        $BUILD$||shared_repl_set_tables||$BUILD$;

  $BUILD$||shared_mixed_obj_logic||$BUILD$

  END IF;

$BUILD$||shared_exception_handler||$BUILD$
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
              AND object_identity ~* c_include_schema_regex
              AND object_identity !~* c_exclude_always)
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
  FROM pg_event_trigger_dropped_objects();

  $BUILD$||shared_get_query||$BUILD$

  IF (v_match_count > 0 AND v_excluded_count = 0)

      THEN

        $BUILD$||shared_deploy_logic||$BUILD$

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

  $BUILD$||shared_mixed_obj_logic||$BUILD$

  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
  AS auto_replication_drop_function,

$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_unsupported_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

 $BUILD$||shared_objects_check||$BUILD$

  IF v_match_count > 0
    THEN

    --Fresh snapshot for pg_stat_activity
    PERFORM pg_stat_clear_snapshot();

    SELECT query
    INTO v_ddl_sql_raw
    FROM pgl_ddl_deploy.stat_activity();
    
    PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'unsupported_command',
               v_backend_xmin);
  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
  AS auto_replication_unsupported_function,

$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_trigger_name||$BUILD$ ON ddl_command_end
WHEN TAG IN(
  'ALTER TABLE'
  ,'CREATE SEQUENCE'
  ,'ALTER SEQUENCE'
  ,'CREATE SCHEMA'
  ,'CREATE TABLE'
  ,'CREATE FUNCTION'
  ,'ALTER FUNCTION'
  ,'CREATE TYPE'
  ,'ALTER TYPE'
  ,'CREATE VIEW'
  ,'ALTER VIEW')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$||auto_replication_function_name||$BUILD$();
$BUILD$::TEXT AS auto_replication_trigger,

$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ ON sql_drop
WHEN TAG IN(
  'DROP SCHEMA'
  ,'DROP TABLE'
  ,'DROP FUNCTION'
  ,'DROP TYPE'
  ,'DROP VIEW'
  ,'DROP SEQUENCE')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$||auto_replication_drop_function_name||$BUILD$();
$BUILD$::TEXT AS auto_replication_drop_trigger,

$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ ON ddl_command_end 
WHEN TAG IN(
  'CREATE TABLE AS'
  ,'SELECT INTO'
  )
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$||auto_replication_unsupported_function_name||$BUILD$();
$BUILD$::TEXT AS auto_replication_unsupported_trigger
FROM vars)

SELECT b.set_name,
  b.auto_replication_function_name,
  b.auto_replication_drop_function_name,
  b.auto_replication_unsupported_function_name,
  b.auto_replication_trigger_name,
  b.auto_replication_drop_trigger_name,
  b.auto_replication_unsupported_trigger_name,
  b.auto_replication_function,
  b.auto_replication_drop_function,
  b.auto_replication_unsupported_function,
  b.auto_replication_trigger,
  b.auto_replication_drop_trigger,
  b.auto_replication_unsupported_trigger,
  $BUILD$
  DROP TABLE IF EXISTS tmp_objs;
  CREATE TEMP TABLE tmp_objs (obj_type, obj_name) AS (
  VALUES
    ('EVENT TRIGGER','$BUILD$||auto_replication_trigger_name||$BUILD$'),
    ('EVENT TRIGGER','$BUILD$||auto_replication_drop_trigger_name||$BUILD$'),
    ('EVENT TRIGGER','$BUILD$||auto_replication_unsupported_trigger_name||$BUILD$'),
    ('FUNCTION','$BUILD$||auto_replication_function_name||$BUILD$()'),
    ('FUNCTION','$BUILD$||auto_replication_drop_function_name||$BUILD$()'),
    ('FUNCTION','$BUILD$||auto_replication_unsupported_function_name||$BUILD$()')
  );

  SELECT pgl_ddl_deploy.drop_ext_object(obj_type, obj_name)
  FROM tmp_objs;
  DROP EVENT TRIGGER IF EXISTS $BUILD$||auto_replication_trigger_name||', '||auto_replication_drop_trigger_name||', '||auto_replication_unsupported_trigger_name||$BUILD$;
  DROP FUNCTION IF EXISTS $BUILD$||auto_replication_function_name||$BUILD$();
  DROP FUNCTION IF EXISTS $BUILD$||auto_replication_drop_function_name||$BUILD$();
  DROP FUNCTION IF EXISTS $BUILD$||auto_replication_unsupported_function_name||$BUILD$();
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
  ALTER EVENT TRIGGER $BUILD$||auto_replication_trigger_name||$BUILD$ DISABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ DISABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ DISABLE;
  $BUILD$ AS disable_sql,
  $BUILD$
  ALTER EVENT TRIGGER $BUILD$||auto_replication_trigger_name||$BUILD$ ENABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ ENABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ ENABLE;
  $BUILD$ AS enable_sql
FROM build b;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_include_schema_regex TEXT;  
BEGIN

SELECT include_schema_regex
INTO c_include_schema_regex
FROM pgl_ddl_deploy.set_configs
WHERE set_name = p_set_name; 

SELECT COUNT(1)
INTO v_count
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
    FROM pglogical.replication_set_relation rsr
    INNER JOIN pglogical.replication_set r
      ON r.set_id = rsr.set_id
    WHERE r.set_name = p_set_name
      AND rsr.set_reloid = c.oid);

IF v_count > 0 THEN
  RAISE WARNING $ERR$
  Deployment of auto-replication for set % failed
  because % tables are already queued to be added to replication
  based on your configuration.  These tables need to be added to
  replication manually and synced, otherwise change your configuration.
  Debug query: %$ERR$,
    p_set_name,
    v_count,
    $SQL$
    SELECT n.nspname, c.relname 
    FROM pg_namespace n
      INNER JOIN pg_class c ON n.oid = c.relnamespace
        AND c.relpersistence = 'p'
      WHERE n.nspname ~* '$SQL$||c_include_schema_regex||$SQL$'
        AND n.nspname !~* '$SQL$||c_exclude_always||$SQL$'
        AND EXISTS (SELECT 1
        FROM pg_index i
        WHERE i.indrelid = c.oid
          AND i.indisprimary)
        AND NOT EXISTS
        (SELECT 1
        FROM pglogical.replication_set_relation rsr
        INNER JOIN pglogical.replication_set r
          ON r.set_id = rsr.set_id
        WHERE r.set_name = '$SQL$||p_set_name||$SQL$'
          AND rsr.set_reloid = c.oid);
    $SQL$;
    RETURN FALSE;
END IF;

RETURN TRUE;

END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deploy(p_set_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_deployable BOOLEAN;
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.deployment_check(p_set_name) INTO v_deployable;
  IF v_deployable THEN
    SELECT pgl_ddl_deploy.schema_execute(p_set_name, 'deploy_sql') INTO v_result;
    RETURN v_result;
  ELSE
    RETURN v_deployable;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.enable(p_set_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_deployable BOOLEAN;
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.deployment_check(p_set_name) INTO v_deployable;
  IF v_deployable THEN
    SELECT pgl_ddl_deploy.schema_execute(p_set_name, 'enable_sql') INTO v_result;
    RETURN v_result;
  ELSE
    RETURN v_deployable;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.disable(p_set_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.schema_execute(p_set_name, 'disable_sql') INTO v_result;
  RETURN v_result;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.schema_execute(p_set_name text, p_field_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_in_sql TEXT;
  v_out_sql TEXT;
BEGIN
  v_in_sql = $$(SELECT $$||p_field_name||$$
                FROM pgl_ddl_deploy.event_trigger_schema
                WHERE set_name = '$$||p_set_name||$$');$$;
  EXECUTE v_in_sql INTO v_out_sql;
  IF v_out_sql IS NULL THEN
    RETURN FALSE;
  ELSE
    EXECUTE v_out_sql;
    RETURN TRUE;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_role(p_roleoid oid)
RETURNS BOOLEAN AS $BODY$
/******
Assuming roles doing DDL are not superusers, this function grants needed privileges
to run through the pgl_ddl_deploy DDL deployment.
This needs to be run on BOTH provider and subscriber.
******/
DECLARE
    v_rec RECORD;
    v_sql TEXT;
BEGIN

    FOR v_rec IN
        SELECT quote_ident(rolname) AS rolname FROM pg_roles WHERE oid = p_roleoid
    LOOP

    v_sql:='
    GRANT USAGE ON SCHEMA pglogical TO '||v_rec.rolname||';
    GRANT USAGE ON SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replicate_ddl_command(text, text[]) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replication_set_add_table(name, regclass, boolean) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) TO '||v_rec.rolname||';
    GRANT INSERT, UPDATE, SELECT ON ALL TABLES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO '||v_rec.rolname||';';
    
    EXECUTE v_sql;
    RETURN true; 
    END LOOP;
RETURN false;
END;
$BODY$
LANGUAGE plpgsql;

GRANT USAGE ON SCHEMA pgl_ddl_deploy TO PUBLIC;
GRANT USAGE ON SCHEMA pglogical TO PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pglogical FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pglogical.dependency_check_trigger() TO PUBLIC;
GRANT EXECUTE ON FUNCTION pglogical.truncate_trigger_add() TO PUBLIC;
REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) FROM PUBLIC;
