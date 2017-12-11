-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

/***
2 Changes:
- This was causing issues due to event triggers firing.  Disable via session_replication_role.
- We need to re-grant access to the view after dependency_update.
****/
CREATE OR REPLACE FUNCTION pgl_ddl_deploy.dependency_update()
RETURNS VOID AS
$DEPS$
DECLARE
    v_sql TEXT;
    v_rep_set_add_table TEXT;
BEGIN

IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'rep_set_table_wrapper' AND table_schema = 'pgl_ddl_deploy') THEN
    PERFORM pgl_ddl_deploy.drop_ext_object('VIEW','pgl_ddl_deploy.rep_set_table_wrapper');
    DROP VIEW pgl_ddl_deploy.rep_set_table_wrapper;
END IF;
IF (SELECT extversion FROM pg_extension WHERE extname = 'pglogical') ~* '^1.*' THEN

    CREATE VIEW pgl_ddl_deploy.rep_set_table_wrapper AS
    SELECT *
    FROM pglogical.replication_set_relation;

    v_rep_set_add_table = 'pglogical.replication_set_add_table(name, regclass, boolean)';

ELSE

    CREATE VIEW pgl_ddl_deploy.rep_set_table_wrapper AS
    SELECT *
    FROM pglogical.replication_set_table;

    v_rep_set_add_table = 'pglogical.replication_set_add_table(name, regclass, boolean, text[], text)';

END IF;

GRANT SELECT ON TABLE pgl_ddl_deploy.rep_set_table_wrapper TO PUBLIC;

v_sql:=$$
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
    GRANT EXECUTE ON FUNCTION $$||v_rep_set_add_table||$$ TO '||v_rec.rolname||';
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
$$;

EXECUTE v_sql;

END;
$DEPS$
LANGUAGE plpgsql
SET SESSION_REPLICATION_ROLE TO REPLICA;
/****
We first need to drop existing event triggers and functions, because the naming convention is
changing
 */
DROP TABLE IF EXISTS tmp_objs;
CREATE TEMP TABLE tmp_objs AS
WITH old_named_objects AS
(SELECT set_name,

  'pgl_ddl_deploy.auto_replicate_ddl_'||set_name||'()' AS auto_replication_function_name,
  'pgl_ddl_deploy.auto_replicate_ddl_drop_'||set_name||'()' AS auto_replication_drop_function_name,
  'pgl_ddl_deploy.auto_replicate_ddl_unsupported_'||set_name||'()' AS auto_replication_unsupported_function_name,
  'auto_replicate_ddl_'||set_name AS auto_replication_trigger_name,
  'auto_replicate_ddl_drop_'||set_name AS auto_replication_drop_trigger_name,
  'auto_replicate_ddl_unsupported_'||set_name AS auto_replication_unsupported_trigger_name

FROM pgl_ddl_deploy.set_configs)
  
SELECT set_name, 'EVENT TRIGGER' AS obj_type, auto_replication_trigger_name AS obj_name FROM old_named_objects UNION ALL
SELECT set_name, 'EVENT TRIGGER' AS obj_type, auto_replication_drop_trigger_name AS obj_name FROM old_named_objects UNION ALL
SELECT set_name, 'EVENT TRIGGER' AS obj_type, auto_replication_unsupported_trigger_name AS obj_name FROM old_named_objects UNION ALL
SELECT set_name, 'FUNCTION' AS obj_type, auto_replication_function_name AS obj_name FROM old_named_objects UNION ALL
SELECT set_name, 'FUNCTION' AS obj_type, auto_replication_drop_function_name AS obj_name FROM old_named_objects UNION ALL
SELECT set_name, 'FUNCTION' AS obj_type, auto_replication_unsupported_function_name AS obj_name FROM old_named_objects
;

SELECT pgl_ddl_deploy.drop_ext_object(obj_type, obj_name)
FROM tmp_objs;

DO $BUILD$
DECLARE
  v_rec RECORD;
  v_sql TEXT;
BEGIN
  
FOR v_rec IN 
  SELECT * FROM tmp_objs WHERE obj_type = 'EVENT TRIGGER'
LOOP

v_sql = $$DROP EVENT TRIGGER IF EXISTS $$||v_rec.obj_name||$$;$$;
EXECUTE v_sql;
RAISE WARNING 'Event trigger % dropped', v_rec.obj_name;

END LOOP;

FOR v_rec IN
  SELECT * FROM tmp_objs WHERE obj_type = 'FUNCTION'
LOOP
v_sql = $$DROP FUNCTION IF EXISTS $$||v_rec.obj_name||$$;$$;
EXECUTE v_sql;
RAISE WARNING 'Function % dropped', v_rec.obj_name;

END LOOP;

FOR v_rec IN
  SELECT DISTINCT set_name FROM tmp_objs
LOOP
RAISE WARNING $$Objects changed - you must manually re-deploy using pgl_ddl_deploy.deploy('%')$$, v_rec.set_name;
END LOOP;

END
$BUILD$;

CREATE FUNCTION pgl_ddl_deploy.standard_create_tags()
RETURNS TEXT[] AS
$BODY$
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
  }'::TEXT[];
$BODY$
LANGUAGE SQL IMMUTABLE;

CREATE FUNCTION pgl_ddl_deploy.standard_drop_tags()
RETURNS TEXT[] AS
$BODY$
SELECT '{
  "DROP SCHEMA"
  ,"DROP TABLE"
  ,"DROP FUNCTION"
  ,"DROP TYPE"
  ,"DROP VIEW"
  ,"DROP SEQUENCE"  
  }'::TEXT[];
$BODY$
LANGUAGE SQL IMMUTABLE;

CREATE FUNCTION pgl_ddl_deploy.unsupported_tags()
RETURNS TEXT[] AS
$BODY$
SELECT '{
  "CREATE TABLE AS"
  ,"SELECT INTO"
  }'::TEXT[];
$BODY$
LANGUAGE SQL IMMUTABLE;

ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN id SERIAL;
ALTER TABLE pgl_ddl_deploy.set_configs DROP CONSTRAINT set_configs_pkey;
ALTER TABLE pgl_ddl_deploy.set_configs ADD PRIMARY KEY (id);
ALTER TABLE pgl_ddl_deploy.commands ADD COLUMN set_config_id INT REFERENCES pgl_ddl_deploy.set_configs (id);
ALTER TABLE pgl_ddl_deploy.events ADD COLUMN set_config_id INT REFERENCES pgl_ddl_deploy.set_configs (id);
ALTER TABLE pgl_ddl_deploy.unhandled ADD COLUMN set_config_id INT REFERENCES pgl_ddl_deploy.set_configs (id);
ALTER TABLE pgl_ddl_deploy.exceptions ADD COLUMN set_config_id INT REFERENCES pgl_ddl_deploy.set_configs (id);

ALTER EXTENSION pgl_ddl_deploy
DROP FUNCTION pgl_ddl_deploy.log_unhandled
(TEXT,
 INT,
 TEXT,
 TEXT,
 TEXT,
 BIGINT);
DROP FUNCTION pgl_ddl_deploy.log_unhandled
(TEXT,
 INT,
 TEXT,
 TEXT,
 TEXT,
 BIGINT);
CREATE FUNCTION pgl_ddl_deploy.log_unhandled
(p_set_config_id INT,
 p_set_name TEXT,
 p_pid INT,
 p_ddl_sql_raw TEXT,
 p_command_tag TEXT,
 p_reason TEXT,
 p_txid BIGINT)
RETURNS VOID AS
$BODY$
DECLARE
    c_unhandled_msg TEXT = 'Unhandled deployment logged in pgl_ddl_deploy.unhandled';
BEGIN
INSERT INTO pgl_ddl_deploy.unhandled
  (set_config_id,
   set_name,
   pid,
   executed_at,
   ddl_sql_raw,
   command_tag,
   reason,
   txid)
VALUES
  (p_set_config_id,
   p_set_name,
   p_pid,
   current_timestamp,
   p_ddl_sql_raw,
   p_command_tag,
   p_reason,
   p_txid);
RAISE WARNING '%', c_unhandled_msg;
END;
$BODY$
LANGUAGE plpgsql;

--Allow specific tables or include regex
ALTER TABLE pgl_ddl_deploy.set_configs ALTER COLUMN include_schema_regex DROP NOT NULL;
ALTER TABLE pgl_ddl_deploy.set_configs DROP CONSTRAINT valid_regex;
ALTER TABLE pgl_ddl_deploy.set_configs ADD CONSTRAINT valid_regex CHECK (include_schema_regex IS NULL OR (CASE WHEN regexp_replace('',include_schema_regex,'') = '' THEN TRUE ELSE FALSE END));
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN include_only_repset_tables BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE pgl_ddl_deploy.set_configs ADD CONSTRAINT repset_tables_or_regex_inclusion CHECK ((include_schema_regex IS NOT NULL AND NOT include_only_repset_tables) OR (include_only_repset_tables AND include_schema_regex IS NULL));

--Customize command tags
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN create_tags TEXT[] DEFAULT pgl_ddl_deploy.standard_create_tags();
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN drop_tags TEXT[] DEFAULT pgl_ddl_deploy.standard_drop_tags();
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN blacklisted_tags TEXT[] DEFAULT pgl_ddl_deploy.blacklisted_tags();

--Allow failures
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN queue_subscriber_failures BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE pgl_ddl_deploy.set_configs ADD CONSTRAINT repset_tables_only_alter_table CHECK ((NOT include_only_repset_tables) OR (include_only_repset_tables AND create_tags = '{"ALTER TABLE"}' AND drop_tags IS NULL));

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.unique_tags()
RETURNS TRIGGER AS
$BODY$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pgl_ddl_deploy.set_configs
    WHERE id <> NEW.id
      AND set_name = NEW.set_name
      AND (create_tags && NEW.create_tags
      OR drop_tags && NEW.drop_tags)) THEN
    RAISE EXCEPTION $$Another set_config already exists for '%' with overlapping create_tags or drop_tags.
    Command tags must only appear once per set_name even if using multiple set_configs.
    $$, NEW.set_name;
  END IF;
  RETURN NEW;
END;
$BODY$
LANGUAGE plpgsql;

CREATE TRIGGER unique_tags
BEFORE INSERT OR UPDATE ON pgl_ddl_deploy.set_configs
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.unique_tags();

ALTER TABLE pgl_ddl_deploy.subscriber_logs
 ADD COLUMN full_ddl_sql TEXT,
 ADD COLUMN origin_subscriber_log_id INT NULL REFERENCES pgl_ddl_deploy.subscriber_logs(id),
 ADD COLUMN next_subscriber_log_id INT NULL REFERENCES pgl_ddl_deploy.subscriber_logs(id),
 ADD COLUMN provider_node_name TEXT,
 ADD COLUMN provider_set_config_id INT,
 ADD COLUMN executed_as_role TEXT DEFAULT current_role,
 ADD COLUMN retrying BOOLEAN NOT NULL DEFAULT FALSE,
 ADD COLUMN succeeded BOOLEAN NULL,
 ADD COLUMN error_message TEXT;

CREATE FUNCTION pgl_ddl_deploy.set_origin_subscriber_log_id()
RETURNS TRIGGER AS
$BODY$
BEGIN
NEW.origin_subscriber_log_id = NEW.id;
RETURN NEW;
END;
$BODY$
LANGUAGE plpgsql;

CREATE TRIGGER set_origin_subscriber_log_id
BEFORE INSERT ON pgl_ddl_deploy.subscriber_logs
FOR EACH ROW WHEN (NEW.origin_subscriber_log_id IS NULL)
EXECUTE PROCEDURE pgl_ddl_deploy.set_origin_subscriber_log_id();

ALTER TABLE pgl_ddl_deploy.subscriber_logs ENABLE REPLICA TRIGGER set_origin_subscriber_log_id;

CREATE UNIQUE INDEX unique_untried ON pgl_ddl_deploy.subscriber_logs (origin_subscriber_log_id) WHERE NOT succeeded AND next_subscriber_log_id IS NULL AND NOT retrying;
CREATE UNIQUE INDEX unique_retrying ON pgl_ddl_deploy.subscriber_logs (origin_subscriber_log_id) WHERE retrying;
CREATE UNIQUE INDEX unique_succeeded ON pgl_ddl_deploy.subscriber_logs (origin_subscriber_log_id) WHERE succeeded;

CREATE FUNCTION pgl_ddl_deploy.fail_queued_attempt(p_subscriber_log_id INT, p_error_message TEXT)
RETURNS VOID AS
$BODY$
DECLARE
  v_new_subscriber_log_id INT;
BEGIN

INSERT INTO pgl_ddl_deploy.subscriber_logs
    (set_name,
    provider_pid,
    subscriber_pid,
    ddl_sql,
    full_ddl_sql,
    origin_subscriber_log_id,
    provider_node_name,
    provider_set_config_id,
    executed_as_role,
    error_message,
    succeeded)
SELECT
    set_name,
    provider_pid,
    pg_backend_pid(),
    ddl_sql,
    full_ddl_sql,
    origin_subscriber_log_id,
    provider_node_name,
    provider_set_config_id,
    executed_as_role,
    p_error_message,
    FALSE
FROM pgl_ddl_deploy.subscriber_logs
WHERE id = p_subscriber_log_id
RETURNING id INTO v_new_subscriber_log_id;

UPDATE pgl_ddl_deploy.subscriber_logs
SET next_subscriber_log_id = v_new_subscriber_log_id
WHERE id = p_subscriber_log_id;

END;
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION pgl_ddl_deploy.retry_subscriber_log(p_subscriber_log_id INT)
RETURNS BOOLEAN AS
$BODY$
DECLARE
    v_sql TEXT;
    v_role TEXT;
    v_return BOOLEAN;
BEGIN
    IF (SELECT retrying FROM pgl_ddl_deploy.subscriber_logs
        WHERE id = p_subscriber_log_id) = TRUE THEN
      RAISE WARNING 'This subscriber_log_id is already executing.  No action will be taken.';
      RETURN FALSE;
    END IF;

    SELECT full_ddl_sql, executed_as_role
    INTO v_sql, v_role
    FROM pgl_ddl_deploy.subscriber_logs
    WHERE id = p_subscriber_log_id;

    UPDATE pgl_ddl_deploy.subscriber_logs
    SET retrying = TRUE
    WHERE id = p_subscriber_log_id;

  BEGIN
      /**
      This needs to be a DO block because currently,the final SQL sent to subscriber is always within a DO block
       */
      v_sql = $$
      DO $RETRY$
      BEGIN

      SET ROLE $$||quote_ident(v_role)||$$;

      $$||v_sql||$$

      END$RETRY$;
      $$;
      EXECUTE v_sql;
      RESET ROLE;

      WITH success AS (
      INSERT INTO pgl_ddl_deploy.subscriber_logs
          (set_name,
          provider_pid,
          subscriber_pid,
          ddl_sql,
          full_ddl_sql,
          origin_subscriber_log_id,
          provider_node_name,
          provider_set_config_id,
          executed_as_role,
          succeeded)
      SELECT
          set_name,
          provider_pid,
          pg_backend_pid(),
          ddl_sql,
          full_ddl_sql,
          origin_subscriber_log_id,
          provider_node_name,
          provider_set_config_id,
          executed_as_role,
          TRUE
      FROM pgl_ddl_deploy.subscriber_logs
      WHERE id = p_subscriber_log_id
      RETURNING *
      )

      UPDATE pgl_ddl_deploy.subscriber_logs
      SET next_subscriber_log_id = (SELECT id FROM success)
      WHERE id = p_subscriber_log_id;

      v_return = TRUE;

  EXCEPTION WHEN OTHERS THEN
      PERFORM pgl_ddl_deploy.fail_queued_attempt(p_subscriber_log_id, SQLERRM);
      v_return = FALSE;
  END;

  UPDATE pgl_ddl_deploy.subscriber_logs
  SET retrying = FALSE
  WHERE id = p_subscriber_log_id;

  RETURN v_return;

END;
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION pgl_ddl_deploy.retry_all_subscriber_logs()
RETURNS BOOLEAN[] AS
$BODY$
DECLARE
    v_rec RECORD;
    v_result BOOLEAN;
    v_results BOOLEAN[];
BEGIN

FOR v_rec IN
  SELECT
    rq.id
  FROM pgl_ddl_deploy.subscriber_logs rq
  INNER JOIN pgl_ddl_deploy.subscriber_logs rqo ON rqo.id = rq.origin_subscriber_log_id
  WHERE NOT rq.succeeded AND rq.next_subscriber_log_id IS NULL AND NOT rq.retrying
  ORDER BY rqo.executed_at ASC, rqo.origin_subscriber_log_id ASC
LOOP

  SELECT pgl_ddl_deploy.retry_subscriber_log(v_rec.id) INTO v_result;
  v_results = array_append(v_results, v_result);
  IF NOT v_result THEN
    RETURN v_results;
  END IF;

END LOOP;

RETURN v_results;

END;
$BODY$
LANGUAGE plpgsql;

--Allow a mechanism to mark unhandled and exceptions as resolved for monitoring purposes
ALTER TABLE pgl_ddl_deploy.unhandled ADD COLUMN resolved BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE pgl_ddl_deploy.unhandled ADD COLUMN resolved_notes TEXT NULL;
ALTER TABLE pgl_ddl_deploy.exceptions ADD COLUMN resolved BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE pgl_ddl_deploy.exceptions ADD COLUMN resolved_notes TEXT NULL;

CREATE FUNCTION pgl_ddl_deploy.resolve_unhandled(p_unhandled_id INT, p_notes TEXT = NULL)
RETURNS BOOLEAN AS
$BODY$
BEGIN
  UPDATE pgl_ddl_deploy.unhandled
  SET resolved = TRUE,
    resolved_notes = p_notes
  WHERE id = p_unhandled_id;
END;
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION pgl_ddl_deploy.resolve_exception(p_exception_id INT, p_notes TEXT = NULL)
RETURNS BOOLEAN AS
$BODY$
BEGIN
  UPDATE pgl_ddl_deploy.exceptions
  SET resolved = TRUE,
    resolved_notes = p_notes
  WHERE id = p_exception_id;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check_count(p_set_config_id int, p_set_name text, p_include_schema_regex text) RETURNS BOOLEAN AS
$BODY$
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
    FROM pgl_ddl_deploy.rep_set_table_wrapper rsr
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
        FROM pgl_ddl_deploy.rep_set_table_wrapper rsr
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

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_set_config_id INT;
  c_include_schema_regex TEXT;
BEGIN

IF NOT EXISTS (SELECT 1 FROM pgl_ddl_deploy.set_configs WHERE set_name = p_set_name) THEN
  RETURN FALSE;
END IF;

--This check only applicable to non-include_only_repset_tables and sets using CREATE TABLE events
SELECT id, include_schema_regex
INTO c_set_config_id, c_include_schema_regex
FROM pgl_ddl_deploy.set_configs
WHERE set_name = p_set_name
  AND NOT include_only_repset_tables
  AND create_tags && '{"CREATE TABLE"}'::TEXT[];

RETURN pgl_ddl_deploy.deployment_check_count(c_set_config_id, p_set_name, c_include_schema_regex);

END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_config_id int) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_set_config_id INT;
  c_include_schema_regex TEXT;
  c_set_name TEXT;
BEGIN

IF NOT EXISTS (SELECT 1 FROM pgl_ddl_deploy.set_configs WHERE id = p_set_config_id) THEN
  RETURN FALSE;
END IF;

--This check only applicable to non-include_only_repset_tables and sets using CREATE TABLE events
--We re-assign set_config_id because we want to know if no records are found, leading to NULL
SELECT id, include_schema_regex, set_name
INTO c_set_config_id, c_include_schema_regex, c_set_name
FROM pgl_ddl_deploy.set_configs
WHERE id = p_set_config_id 
  AND NOT include_only_repset_tables
  AND create_tags && '{"CREATE TABLE"}'::TEXT[];

RETURN pgl_ddl_deploy.deployment_check_count(c_set_config_id, c_set_name, c_include_schema_regex);

END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deploy(p_set_config_id int) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_deployable BOOLEAN;
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.deployment_check(p_set_config_id) INTO v_deployable;
  IF v_deployable THEN
    SELECT pgl_ddl_deploy.schema_execute(p_set_config_id, 'deploy_sql') INTO v_result;
    RETURN v_result;
  ELSE
    RETURN v_deployable;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.enable(p_set_config_id int) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_deployable BOOLEAN;
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.deployment_check(p_set_config_id) INTO v_deployable;
  IF v_deployable THEN
    SELECT pgl_ddl_deploy.schema_execute(p_set_config_id, 'enable_sql') INTO v_result;
    RETURN v_result;
  ELSE
    RETURN v_deployable;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.disable(p_set_config_id int) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.schema_execute(p_set_config_id, 'disable_sql') INTO v_result;
  RETURN v_result;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.schema_execute(p_set_name text, p_field_name text) RETURNS BOOLEAN AS
$BODY$
/****
This function will deploy SQL for all set_configs with given set_name, since this is now allowed.
The version of this function with (int, text) uses a single set_config_id to deploy
 */
DECLARE
  v_rec RECORD;
  v_in_sql TEXT;
  v_out_sql TEXT;
BEGIN
  FOR v_rec IN
    SELECT id
    FROM pgl_ddl_deploy.set_configs
    WHERE set_name = p_set_name
  LOOP
  v_in_sql = $$(SELECT $$||p_field_name||$$
                FROM pgl_ddl_deploy.event_trigger_schema
                WHERE id = $$||v_rec.id||$$
                  AND set_name = '$$||p_set_name||$$');$$;
  EXECUTE v_in_sql INTO v_out_sql;
  IF v_out_sql IS NULL THEN
    RAISE WARNING 'Failed execution for id % set %', v_rec.id, p_set_name;
    RETURN FALSE;
  ELSE
    EXECUTE v_out_sql;
  END IF;

  END LOOP;
  RETURN TRUE;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.schema_execute(p_set_config_id int, p_field_name text) RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_rec RECORD;
  v_in_sql TEXT;
  v_out_sql TEXT;
BEGIN
  v_in_sql = $$(SELECT $$||p_field_name||$$
                FROM pgl_ddl_deploy.event_trigger_schema
                WHERE id = $$||p_set_config_id||$$);$$;
  EXECUTE v_in_sql INTO v_out_sql;
  IF v_out_sql IS NULL THEN
    RAISE WARNING 'Failed execution for id % set %', p_set_config_id, (SELECT set_name FROM pgl_ddl_deploy.set_configs WHERE id = p_set_config_id);
    RETURN FALSE;
  ELSE
    EXECUTE v_out_sql;
    RETURN TRUE;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;

ALTER EXTENSION pgl_ddl_deploy DROP VIEW pgl_ddl_deploy.event_trigger_schema;
DROP VIEW pgl_ddl_deploy.event_trigger_schema;
CREATE VIEW pgl_ddl_deploy.event_trigger_schema AS
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
            SET SEARCH_PATH TO $INNER_BLOCK$||c_search_path||$INNER_BLOCK$;

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
    FROM pgl_ddl_deploy.rep_set_table_wrapper rsr
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
                FROM pgl_ddl_deploy.rep_set_table_wrapper rsr
                INNER JOIN pglogical.replication_set rs USING (set_id)
                WHERE rsr.set_reloid = c.objid
                  AND c.object_type = 'table'
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
          We do not filter to tags here, because of possibility of multi-statement SQL
        **/
        IF NOT $BUILD$||include_only_repset_tables||$BUILD$ THEN
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

$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ ON ddl_command_end
WHEN TAG IN('$BUILD$||array_to_string(pgl_ddl_deploy.unsupported_tags(),$$','$$)||$BUILD$')
EXECUTE PROCEDURE $BUILD$||auto_replication_unsupported_function_name||$BUILD$();
$BUILD$::TEXT AS auto_replication_unsupported_trigger
FROM vars)

SELECT
  b.id,
  b.set_name,
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
  $BUILD$ AS enable_sql
FROM build b;

--Just do this to avoid unneeded complexity with dependency_update
GRANT SELECT ON TABLE pgl_ddl_deploy.rep_set_table_wrapper TO PUBLIC;