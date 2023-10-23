/* pgl_ddl_deploy--1.3--1.4.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT id, pgl_ddl_deploy.undeploy(id) AS undeployed
FROM pgl_ddl_deploy.event_trigger_schema
WHERE is_deployed;

SELECT pgl_ddl_deploy.drop_ext_object('FUNCTION','pgl_ddl_deploy.dependency_update()');
DROP FUNCTION pgl_ddl_deploy.dependency_update();
SELECT pgl_ddl_deploy.drop_ext_object('VIEW','pgl_ddl_deploy.rep_set_table_wrapper');
DROP VIEW IF EXISTS pgl_ddl_deploy.rep_set_table_wrapper; 

ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN exclude_alter_table_subcommands TEXT[];

ALTER TABLE pgl_ddl_deploy.set_configs DROP CONSTRAINT repset_tables_only_alter_table;

SELECT pg_catalog.pg_extension_config_dump('pgl_ddl_deploy.set_configs_id_seq', '');

ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN ddl_only_replication BOOLEAN NOT NULL DEFAULT FALSE;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.rep_set_table_wrapper()
 RETURNS TABLE (set_id OID, set_reloid REGCLASS)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
/*****
This handles the rename of pglogical.replication_set_relation to pglogical.replication_set_table from version 1 to 2
 */
BEGIN

IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_table') THEN
    RETURN QUERY
    SELECT r.set_id, r.set_reloid 
    FROM pglogical.replication_set_table r;

ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_relation') THEN
    RETURN QUERY
    SELECT r.set_id, r.set_reloid 
    FROM pglogical.replication_set_relation r;

ELSE
    RAISE EXCEPTION 'No table pglogical.replication_set_relation or pglogical.replication_set_table found';
END IF;

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
SELECT id, include_schema_regex, set_name, include_only_repset_tables, ddl_only_replication
INTO c_set_config_id, c_include_schema_regex, c_set_name, v_include_only_repset_tables, v_ddl_only_replication
FROM pgl_ddl_deploy.set_configs
WHERE ((p_set_name is null and id = p_set_config_id)
  OR (p_set_config_id is null and set_name = p_set_name))
  AND create_tags && '{"CREATE TABLE"}'::TEXT[];

IF v_include_only_repset_tables OR v_ddl_only_replication THEN
    RETURN TRUE;
END IF;

RETURN pgl_ddl_deploy.deployment_check_count(c_set_config_id, c_set_name, c_include_schema_regex);

END;
$function$;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_config_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN

RETURN pgl_ddl_deploy.deployment_check_wrapper(p_set_config_id, NULL); 

END;
$function$;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN

RETURN pgl_ddl_deploy.deployment_check_wrapper(NULL, p_set_name); 

END;
$function$;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check_count(p_set_config_id integer, p_set_name text, p_include_schema_regex text)
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
    INNER JOIN pglogical.replication_set r
      ON r.set_id = rsr.set_id
    WHERE r.set_name = p_set_name
      AND rsr.set_reloid = c.oid);

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
        INNER JOIN pglogical.replication_set r
          ON r.set_id = rsr.set_id
        WHERE r.set_name = '$SQL$||p_set_name||$SQL$'
          AND rsr.set_reloid = c.oid);
    $SQL$;
    RETURN FALSE;
END IF;

RETURN TRUE;

END;
$function$
;

CREATE OR REPLACE VIEW pgl_ddl_deploy.event_trigger_schema AS
WITH vars AS
(SELECT
  id,
   set_name,
  'pgl_ddl_deploy.auto_rep_ddl_create_'||id::TEXT||'_'||set_name AS auto_replication_create_function_name,
  'pgl_ddl_deploy.auto_rep_ddl_drop_'||id::TEXT||'_'||set_name AS auto_replication_drop_function_name,
  'pgl_ddl_deploy.auto_rep_ddl_unsupp_'||id::TEXT||'_'||set_name AS auto_replication_unsupported_function_name,
  'auto_rep_ddl_create_'||id::TEXT||'_'||set_name AS auto_replication_create_trigger_name,
  'auto_rep_ddl_drop_'||id::TEXT||'_'||set_name AS auto_replication_drop_trigger_name,
  'auto_rep_ddl_unsupp_'||id::TEXT||'_'||set_name AS auto_replication_unsupported_trigger_name,
  include_schema_regex,
  include_only_repset_tables,
  create_tags,
  drop_tags,
  ddl_only_replication,

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
  v_excluded_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_exception_msg TEXT = 'Deployment exception logged in pgl_ddl_deploy.exceptions';

  --Configurable options in function setup
  c_set_config_id INT = $BUILD$||id::TEXT||$BUILD$;
  c_set_name TEXT = '$BUILD$||set_name||$BUILD$';
  c_include_schema_regex TEXT = $BUILD$||COALESCE(''''||include_schema_regex||'''','NULL')||$BUILD$;
  c_lock_safe_deployment BOOLEAN = $BUILD$||lock_safe_deployment||$BUILD$;
  c_allow_multi_statements BOOLEAN = $BUILD$||allow_multi_statements||$BUILD$;
  c_include_only_repset_tables BOOLEAN = $BUILD$||include_only_repset_tables||$BUILD$;
  c_queue_subscriber_failures BOOLEAN = $BUILD$||queue_subscriber_failures||$BUILD$;
  c_blacklisted_tags TEXT[] = '$BUILD$||blacklisted_tags::TEXT||$BUILD$';
  c_exclude_alter_table_subcommands TEXT[] = $BUILD$||COALESCE(quote_literal(exclude_alter_table_subcommands::TEXT),'NULL')||$BUILD$;

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
        v_ddl_sql_raw = current_query();
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
                FROM unnest(pgl_ddl_deploy.get_altertable_subcmdinfo(v_cmd_rec.command)) AS subcommand
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
        c_provider_name:=(SELECT n.node_name FROM pglogical.node n INNER JOIN pglogical.local_node ln USING (node_id));

        /*
          Build replication DDL command which will conditionally run only on the subscriber
          In other words, this MUST be a no-op on the provider
          **Because the DDL has already run at this point (ddl_command_end)**
        */
        v_full_ddl:=$INNER_BLOCK$
        --Be sure to use provider's search_path for SQL environment consistency
            SET SEARCH_PATH TO $INNER_BLOCK$||
            CASE WHEN COALESCE(c_search_path,'') IN('','""') THEN quote_literal('') ELSE c_search_path END||$INNER_BLOCK$;

            --Execute DDL - the reason we use execute here is partly to handle no trailing semicolon
            EXECUTE $EXEC_SUBSCRIBER$
            $INNER_BLOCK$||c_exec_prefix||v_ddl_sql_sent||c_exec_suffix||$INNER_BLOCK$
            $EXEC_SUBSCRIBER$;
        $INNER_BLOCK$;

        v_sql:=$INNER_BLOCK$
        SELECT pglogical.replicate_ddl_command($REPLICATE_DDL_COMMAND$
        DO $AUTO_REPLICATE_BLOCK$
        DECLARE
          c_queue_subscriber_failures BOOLEAN = $INNER_BLOCK$||c_queue_subscriber_failures||$INNER_BLOCK$;
          v_succeeded BOOLEAN;
          v_error_message TEXT;
        BEGIN

        --Only run on subscriber with this replication set, and matching provider node name
        IF EXISTS (SELECT 1
                      FROM pglogical.subscription s
                      INNER JOIN pglogical.node n
                        ON n.node_id = s.sub_origin
                        AND n.node_name = '$INNER_BLOCK$||c_provider_name||$INNER_BLOCK$'
                      WHERE sub_replication_sets && ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']) THEN

            v_error_message = NULL;
            BEGIN

             --Execute DDL
             $INNER_BLOCK$||v_full_ddl||$INNER_BLOCK$

             v_succeeded = TRUE;

            EXCEPTION
              WHEN OTHERS THEN
                IF c_queue_subscriber_failures THEN
                  RAISE WARNING 'Subscriber DDL failed with errors (see pgl_ddl_deploy.subscriber_logs): %', SQLERRM;
                  v_succeeded = FALSE;
                  v_error_message = SQLERRM;
                ELSE
                  RAISE;
                END IF;
            END;

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
            ('$INNER_BLOCK$||c_set_name||$INNER_BLOCK$',
             $INNER_BLOCK$||v_pid::TEXT||$INNER_BLOCK$,
             '$INNER_BLOCK$||c_provider_name||$INNER_BLOCK$',
             $INNER_BLOCK$||c_set_config_id::TEXT||$INNER_BLOCK$,
             current_role,
             pg_backend_pid(),
             current_timestamp,
             $SQL$$INNER_BLOCK$||v_ddl_sql_sent||$INNER_BLOCK$$SQL$,
             $SQL$$INNER_BLOCK$||v_full_ddl||$INNER_BLOCK$$SQL$,
             v_succeeded,
             v_error_message);

        END IF;

        END$AUTO_REPLICATE_BLOCK$;
        $REPLICATE_DDL_COMMAND$,
        --Pipe this DDL command through chosen replication set
        ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']);
        $INNER_BLOCK$;

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
    BEGIN
      INSERT INTO pgl_ddl_deploy.exceptions (set_config_id, set_name, pid, executed_at, ddl_sql, err_msg, err_state)
      VALUES (c_set_config_id, c_set_name, v_pid, current_timestamp, v_sql, SQLERRM, SQLSTATE);
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
    INNER JOIN pglogical.replication_set r
      ON r.set_id = rsr.set_id
    WHERE r.set_name = c_set_name
      AND rsr.set_reloid = c.oid)
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
                INNER JOIN pglogical.replication_set rs USING (set_id)
                WHERE rsr.set_reloid = c.objid
                  AND c.object_type in('table','table column','table constraint')
                  AND rs.set_name = '$BUILD$||set_name||$BUILD$'
                )
              )
            )
            THEN 1
          ELSE 0 END) AS match_count
  $BUILD$::TEXT AS shared_match_count
FROM pglogical.replication_set rs
INNER JOIN pgl_ddl_deploy.set_configs sc USING (set_name)
)

, build AS (
SELECT
  id,
  set_name,
  include_schema_regex,
  include_only_repset_tables,
  auto_replication_create_function_name,
  auto_replication_drop_function_name,
  auto_replication_unsupported_function_name,
  auto_replication_create_trigger_name,
  auto_replication_drop_trigger_name,
  auto_replication_unsupported_trigger_name,

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
    INTO v_cmd_count, v_match_count
  FROM pg_event_trigger_ddl_commands() c;

  $BUILD$||shared_get_query||$BUILD$

  IF (v_match_count > 0 AND v_cmd_count = v_match_count)
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
          Add table to replication set immediately, if required.
          We do not filter to tags here, because of possibility of multi-statement SQL.
          Optional ddl_only_replication will never auto-add tables to replication because the
          purpose is to only replicate keep the structure synchronized on the subscriber with no data.
        **/
        IF NOT $BUILD$||include_only_repset_tables||$BUILD$ AND NOT $BUILD$||ddl_only_replication||$BUILD$ THEN
          PERFORM pglogical.replication_set_add_table(
            set_name:=c_set_name
            ,relation:=c.oid
            ,synchronize_data:=false
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
    INTO v_cmd_count, v_match_count, v_excluded_count
  FROM pg_event_trigger_dropped_objects() c;

  $BUILD$||shared_get_query||$BUILD$

  IF (v_match_count > 0 AND v_excluded_count = 0)

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
    INTO v_cmd_count, v_match_count
  FROM pg_event_trigger_ddl_commands() c;

  IF v_match_count > 0
    THEN

    v_ddl_sql_raw = current_query();

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
  auto_replication_function||$BUILD$
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


CREATE FUNCTION pgl_ddl_deploy.get_altertable_subcmdinfo(pg_ddl_command)
  RETURNS text[] IMMUTABLE STRICT
  AS '$libdir/ddl_deparse', 'get_altertable_subcmdinfo' LANGUAGE C;

CREATE FUNCTION pgl_ddl_deploy.get_command_tag(pg_ddl_command)
  RETURNS text IMMUTABLE STRICT
  AS '$libdir/ddl_deparse', 'get_command_tag' LANGUAGE C;

CREATE FUNCTION pgl_ddl_deploy.get_command_type(pg_ddl_command)
  RETURNS text IMMUTABLE STRICT
  AS '$libdir/ddl_deparse', 'get_command_type' LANGUAGE C;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.standard_repset_only_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
  "ALTER TABLE"
  ,COMMENT}'::TEXT[];
$function$
;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.standard_create_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
  "ALTER TABLE"
  ,"CREATE SEQUENCE"
  ,"ALTER SEQUENCE"
  ,"CREATE SCHEMA"
  ,"CREATE TABLE"
  ,"CREATE FUNCTION"
  ,"ALTER FUNCTION"
  ,"CREATE TYPE"
  ,"ALTER TYPE"
  ,"CREATE VIEW"
  ,"ALTER VIEW"
  ,COMMENT}'::TEXT[];
$function$
;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.exclude_regex()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '^(pg_catalog|information_schema|pg_temp.*|pg_toast.*|pgl_ddl_deploy|pglogical|pglogical_ticker|repack)$'::TEXT;
$function$
;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.common_exclude_alter_table_subcommands()
RETURNS TEXT[] AS
$BODY$
SELECT ARRAY[
  'ADD CONSTRAINT',
  'ADD CONSTRAINT (and recurse)',
  '(re) ADD CONSTRAINT',
  'ALTER CONSTRAINT',
  'VALIDATE CONSTRAINT',
  'VALIDATE CONSTRAINT (and recurse)',
  'ADD (processed) CONSTRAINT',
  'ADD CONSTRAINT (using index)',
  'DROP CONSTRAINT',
  'DROP CONSTRAINT (and recurse)',
  'SET LOGGED',
  'SET UNLOGGED',
  'SET TABLESPACE',
  'SET RELOPTIONS',
  'RESET RELOPTIONS',
  'REPLACE RELOPTIONS',
  'ENABLE TRIGGER',
  'ENABLE TRIGGER (always)',
  'ENABLE TRIGGER (replica)',
  'DISABLE TRIGGER',
  'ENABLE TRIGGER (all)',
  'DISABLE TRIGGER (all)',
  'ENABLE TRIGGER (user)',
  'DISABLE TRIGGER (user)',
  'ENABLE RULE',
  'ENABLE RULE (always)',
  'ENABLE RULE (replica)',
  'DISABLE RULE',
  'SET OPTIONS']::TEXT[];
$BODY$
LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.unique_tags()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT NEW.ddl_only_replication AND EXISTS (
    SELECT 1
    FROM pgl_ddl_deploy.set_configs
    WHERE id <> NEW.id
      AND set_name = NEW.set_name
      AND NOT NEW.ddl_only_replication
      AND (create_tags && NEW.create_tags
      OR drop_tags && NEW.drop_tags)) THEN
    RAISE EXCEPTION $$Another set_config already exists for '%' with overlapping create_tags or drop_tags.
    Command tags must only appear once per set_name even if using multiple set_configs, unless you
    are using the ddl_only_replication setting.
    $$, NEW.set_name;
  END IF;
  RETURN NEW;
END;
$function$
;


ALTER TABLE pgl_ddl_deploy.set_configs ADD CONSTRAINT repset_tables_restricted_tags CHECK ((NOT include_only_repset_tables) OR (include_only_repset_tables AND pgl_ddl_deploy.standard_repset_only_tags() @> create_tags AND drop_tags IS NULL));

SELECT id, pgl_ddl_deploy.deploy(id) AS deployed
FROM ddl_deploy_to_refresh;

DROP TABLE ddl_deploy_to_refresh;


