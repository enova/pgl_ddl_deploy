-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

CREATE FUNCTION pgl_ddl_deploy.sql_command_tags(p_sql TEXT)
RETURNS TEXT[] AS
'MODULE_PATHNAME', 'sql_command_tags'
LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_ext_object
  (p_type text
  , p_full_obj_name text)
RETURNS VOID AS
$BODY$
BEGIN
PERFORM pgl_ddl_deploy.toggle_ext_object(p_type, p_full_obj_name, 'ADD');
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.drop_ext_object
  (p_type text
  , p_full_obj_name text)
RETURNS VOID AS
$BODY$
BEGIN
PERFORM pgl_ddl_deploy.toggle_ext_object(p_type, p_full_obj_name, 'DROP');
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.toggle_ext_object
  (p_type text
  , p_full_obj_name text
  , p_toggle text)
RETURNS VOID AS
$BODY$
DECLARE
  c_valid_types TEXT[] = ARRAY['EVENT TRIGGER','FUNCTION','VIEW'];
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
    txid BIGINT
    );

CREATE UNIQUE INDEX ON pgl_ddl_deploy.events (set_name, pid, txid, md5(ddl_sql_raw));

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
    txid BIGINT,
    CONSTRAINT valid_reason CHECK (reason IN('mixed_objects','rejected_command_tags','rejected_multi_statement','unsupported_command'))
    );

CREATE UNIQUE INDEX ON pgl_ddl_deploy.unhandled (set_name, pid, txid, md5(ddl_sql_raw));

CREATE FUNCTION pgl_ddl_deploy.log_unhandled
(p_set_name TEXT,
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
  (set_name,
   pid,
   executed_at,
   ddl_sql_raw,
   command_tag,
   reason,
   txid)
VALUES
  (p_set_name,
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
    txid BIGINT,
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


GRANT USAGE ON SCHEMA pgl_ddl_deploy TO PUBLIC;
DO $$ BEGIN
IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
GRANT USAGE ON SCHEMA pglogical TO PUBLIC; REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pglogical FROM PUBLIC;
END IF;
IF EXISTS (SELECT 1 FROM pg_proc p INNER JOIN pg_namespace n ON n.oid = p.pronamespace WHERE proname = 'dependency_check_trigger' AND nspname = 'pglogical') THEN
    GRANT EXECUTE ON FUNCTION pglogical.dependency_check_trigger() TO PUBLIC;
END IF;
IF EXISTS (SELECT 1 FROM pg_proc p INNER JOIN pg_namespace n ON n.oid = p.pronamespace WHERE proname = 'truncate_trigger_add' AND nspname = 'pglogical') THEN
    GRANT EXECUTE ON FUNCTION pglogical.truncate_trigger_add() TO PUBLIC;
END IF;
END$$;
REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) FROM PUBLIC;
-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

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

--If you don't do this, it will be part of the extension!
DROP TABLE tmp_objs;

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
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN create_tags TEXT[];
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN drop_tags TEXT[];
UPDATE pgl_ddl_deploy.set_configs
SET create_tags = pgl_ddl_deploy.standard_create_tags(),
    drop_tags = pgl_ddl_deploy.standard_drop_tags();
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

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.set_tag_defaults()
RETURNS TRIGGER AS
$BODY$
BEGIN
IF NEW.create_tags IS NULL THEN
    NEW.create_tags = CASE WHEN NEW.include_only_repset_tables THEN '{"ALTER TABLE"}' ELSE pgl_ddl_deploy.standard_create_tags() END;
END IF;
IF NEW.drop_tags IS NULL THEN
    NEW.drop_tags = CASE WHEN NEW.include_only_repset_tables THEN NULL ELSE pgl_ddl_deploy.standard_drop_tags() END;
END IF;
RETURN NEW;
END;
$BODY$
LANGUAGE plpgsql;

CREATE TRIGGER set_tag_defaults
BEFORE INSERT OR UPDATE ON pgl_ddl_deploy.set_configs
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.set_tag_defaults();

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
DECLARE
  v_row_count INT;
BEGIN
  UPDATE pgl_ddl_deploy.unhandled
  SET resolved = TRUE,
    resolved_notes = p_notes
  WHERE id = p_unhandled_id;

  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RETURN (v_row_count > 0);
END;
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION pgl_ddl_deploy.resolve_exception(p_exception_id INT, p_notes TEXT = NULL)
RETURNS BOOLEAN AS
$BODY$
DECLARE
  v_row_count INT;
BEGIN
  UPDATE pgl_ddl_deploy.exceptions
  SET resolved = TRUE,
    resolved_notes = p_notes
  WHERE id = p_exception_id;

  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RETURN (v_row_count > 0);
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


--Just do this to avoid unneeded complexity with dependency_update
-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.undeploy(p_set_config_id int) RETURNS BOOLEAN AS
$BODY$
BEGIN
  RETURN pgl_ddl_deploy.schema_execute(p_set_config_id, 'undeploy_sql');
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.undeploy(p_set_name text) RETURNS BOOLEAN AS
$BODY$
BEGIN
  RETURN pgl_ddl_deploy.schema_execute(p_set_name, 'undeploy_sql');
END;
$BODY$
LANGUAGE plpgsql;


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



/* pgl_ddl_deploy--1.4--1.5.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN include_everything
  BOOLEAN NOT NULL DEFAULT FALSE;

-- Now we have 3 configuration types
ALTER TABLE pgl_ddl_deploy.set_configs
  DROP CONSTRAINT repset_tables_or_regex_inclusion;

-- Only allow one of them to be chosen
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT single_configuration_type
  CHECK
  ((include_schema_regex IS NOT NULL
   AND NOT include_only_repset_tables)
   OR
   (include_only_repset_tables
    AND include_schema_regex IS NULL)
   OR
   (include_everything
    AND NOT include_only_repset_tables
    AND include_schema_regex IS NULL));

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT ddl_only_restrictions
  CHECK (NOT (ddl_only_replication AND include_only_repset_tables)); 

-- Need to adjust to after trigger and change function def 
DROP TRIGGER unique_tags ON pgl_ddl_deploy.set_configs;
DROP FUNCTION pgl_ddl_deploy.unique_tags();


-- Support canceling or terminating blocking processes on subscriber
CREATE TYPE pgl_ddl_deploy.signals AS ENUM ('cancel','terminate','cancel_then_terminate');
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN signal_blocking_subscriber_sessions pgl_ddl_deploy.signals;
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN subscriber_lock_timeout INT;

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT valid_signal_blocker_config
  CHECK
  (NOT (lock_safe_deployment AND (signal_blocking_subscriber_sessions IS NOT NULL OR subscriber_lock_timeout IS NOT NULL))
    AND NOT (subscriber_lock_timeout IS NOT NULL AND signal_blocking_subscriber_sessions IS NULL));

CREATE TABLE pgl_ddl_deploy.killed_blockers
(
  id           SERIAL PRIMARY KEY,
  signal       TEXT,
  successful   BOOLEAN,
  pid          INT,
  executed_at  TIMESTAMPTZ,
  usename      NAME,
  client_addr  INET,
  xact_start   TIMESTAMPTZ,
  state_change TIMESTAMPTZ,
  state        TEXT,
  query        TEXT,
  reported     BOOLEAN DEFAULT FALSE,
  reported_at  TIMESTAMPTZ
);


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.unique_tags()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_output TEXT;
BEGIN
    WITH dupes AS (
    SELECT set_name,
        CASE
            WHEN include_only_repset_tables THEN 'include_only_repset_tables'
            WHEN include_everything AND NOT ddl_only_replication THEN 'include_everything'
            WHEN include_schema_regex IS NOT NULL AND NOT ddl_only_replication THEN 'include_schema_regex'
            WHEN ddl_only_replication THEN
                CASE
                    WHEN include_everything THEN 'ddl_only_include_everything'
                    WHEN include_schema_regex IS NOT NULL THEN 'ddl_only_include_schema_regex'
                END
        END AS category,
    unnest(array_cat(create_tags, drop_tags)) AS command_tag
    FROM pgl_ddl_deploy.set_configs
    GROUP BY 1, 2, 3
    HAVING COUNT(1) > 1)

    , aggregate_dupe_tags AS (
    SELECT set_name, category, string_agg(command_tag, ', ' ORDER BY command_tag) AS command_tags
    FROM dupes
    GROUP BY 1, 2
    )

    SELECT string_agg(format('%s: %s: %s', set_name, category, command_tags), ', ') AS output
    INTO v_output
    FROM aggregate_dupe_tags;

    IF v_output IS NOT NULL THEN
        RAISE EXCEPTION '%', format('You have overlapping configuration types and command tags which is not permitted: %s', v_output);
    END IF;
    RETURN NULL;
END;
$function$
;


CREATE TRIGGER unique_tags
AFTER INSERT OR UPDATE ON pgl_ddl_deploy.set_configs
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.unique_tags();


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.kill_blockers
(p_signal pgl_ddl_deploy.signals,
p_nspname NAME,
p_relname NAME)
RETURNS TABLE (
signal       pgl_ddl_deploy.signals,
successful   BOOLEAN,
raised_message BOOLEAN,
pid          INT,
executed_at  TIMESTAMPTZ,
usename      NAME,
client_addr  INET,
xact_start   TIMESTAMPTZ,
state_change TIMESTAMPTZ,
state        TEXT,
query        TEXT,
reported     BOOLEAN
)
AS
$BODY$
/****
This function is only called on the subscriber on which we are applying DDL,
when it is blocked and hits the configured lock_timeout.

It is called by the function pgl_ddl_deploy.subscriber_command() only if it hits
lock_timeout and it is configured to send a signal to blocking queries.

It has three main features:
    1. Signal blocking sessions with either cancel or terminate.
    2. Raise a WARNING message to server logs in case of a kill attempt
    3. Return the recordset with details of killed queries for auditing purposes.
****/
BEGIN

RETURN QUERY
SELECT p_signal AS signal,
  CASE
    WHEN p_signal IS NULL
      THEN FALSE
    WHEN p_signal = 'cancel'
      THEN pg_cancel_backend(l.pid)
    WHEN p_signal = 'terminate'
      THEN pg_terminate_backend(l.pid)
  END AS successful,
  CASE
    WHEN p_signal IS NULL
      THEN FALSE 
    WHEN p_signal = 'cancel'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attempting cancel of blocking pid %s, query: %s', l.pid, a.query))
    WHEN p_signal = 'terminate'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attempting termination of blocking pid %s, query: %s', l.pid, a.query))
  END AS raised_message,
  l.pid,
  now() AS executed_at,
  a.usename,
  a.client_addr,
  a.xact_start,
  a.state_change,
  a.state,
  a.query,
  FALSE AS reported
FROM pg_locks l
INNER JOIN pg_class c on l.relation = c.oid
INNER JOIN pg_namespace n on c.relnamespace = n.oid
INNER JOIN pg_stat_activity a on l.pid = a.pid
-- We do not exclude either postgres user or pglogical processes, because we even want to cancel autovac blocks.
-- It should not be possible to contend with pglogical write processes (at least as of pglogical 2.2), because
-- these run single-threaded using the same process that is doing the DDL and already holds any lock it needs
-- on the target table.
WHERE NOT a.pid = pg_backend_pid()
-- both nspname and relname will be an empty string, thus a no-op, if for some reason one or the other
-- is not found on the provider side in pg_event_trigger_ddl_commands().  This is a safety mechanism!
AND n.nspname = p_nspname
AND c.relname = p_relname
AND a.datname = current_database()
AND c.relkind = 'r'
AND l.locktype = 'relation'
ORDER BY a.state_change DESC;

END;
$BODY$
SECURITY DEFINER
LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, NAME, NAME) FROM PUBLIC;


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
BEGIN

    FOR v_rec IN
        SELECT quote_ident(rolname) AS rolname FROM pg_roles WHERE oid = p_roleoid
    LOOP

    v_sql:='
    GRANT USAGE ON SCHEMA pglogical TO '||v_rec.rolname||';
    GRANT USAGE ON SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replicate_ddl_command(text, text[]) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replication_set_add_table(name, regclass, boolean, text[], text) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, name, name) TO '||v_rec.rolname||';
    GRANT INSERT, UPDATE, SELECT ON ALL TABLES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO '||v_rec.rolname||';';

    EXECUTE v_sql;
    RETURN true;
    END LOOP;
RETURN false;
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

--Only run on subscriber with this replication set, and matching provider node name
IF EXISTS (SELECT 1
              FROM pglogical.subscription s
              INNER JOIN pglogical.node n
                ON n.node_id = s.sub_origin
                AND n.node_name = p_provider_name
              WHERE sub_replication_sets && p_set_name) OR p_run_anywhere THEN

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


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.raise_message
(p_log_level TEXT,
p_message TEXT)
RETURNS BOOLEAN 
AS $BODY$
BEGIN

EXECUTE format($$
DO $block$
BEGIN
RAISE %s $pgl_ddl_deploy_msg$%s$pgl_ddl_deploy_msg$;
END$block$;
$$, p_log_level, p_message);
RETURN TRUE;

END;
$BODY$
LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.blacklisted_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
        INSERT,
        UPDATE,
        DELETE,
        TRUNCATE,
        ROLLBACK,
        "CREATE EXTENSION",
        "ALTER EXTENSION",
        "DROP EXTENSION"}'::TEXT[];
$function$
;




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


/* pgl_ddl_deploy--1.5--1.6.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

CREATE FUNCTION pgl_ddl_deploy.current_query()
RETURNS TEXT AS
'MODULE_PATHNAME', 'pgl_ddl_deploy_current_query'
LANGUAGE C VOLATILE STRICT;

-- Drop UPDATE event for this trigger, which leads to unexpected behavior
DROP TRIGGER set_tag_defaults ON pgl_ddl_deploy.set_configs;
CREATE TRIGGER set_tag_defaults
BEFORE INSERT ON pgl_ddl_deploy.set_configs
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.set_tag_defaults();



CREATE OR REPLACE FUNCTION pgl_ddl_deploy.kill_blockers
(p_signal pgl_ddl_deploy.signals,
p_nspname NAME,
p_relname NAME)
RETURNS TABLE (
signal       pgl_ddl_deploy.signals,
successful   BOOLEAN,
raised_message BOOLEAN,
pid          INT,
executed_at  TIMESTAMPTZ,
usename      NAME,
client_addr  INET,
xact_start   TIMESTAMPTZ,
state_change TIMESTAMPTZ,
state        TEXT,
query        TEXT,
reported     BOOLEAN
)
AS
$BODY$
/****
This function is only called on the subscriber on which we are applying DDL,
when it is blocked and hits the configured lock_timeout.

It is called by the function pgl_ddl_deploy.subscriber_command() only if it hits
lock_timeout and it is configured to send a signal to blocking queries.

It has three main features:
    1. Signal blocking sessions with either cancel or terminate.
    2. Raise a WARNING message to server logs in case of a kill attempt
    3. Return the recordset with details of killed queries for auditing purposes.
****/
BEGIN

RETURN QUERY
SELECT DISTINCT ON (l.pid)
  p_signal AS signal,
  CASE
    WHEN p_signal IS NULL
      THEN FALSE
    WHEN p_signal = 'cancel'
      THEN pg_cancel_backend(l.pid)
    WHEN p_signal = 'terminate'
      THEN pg_terminate_backend(l.pid)
  END AS successful,
  CASE
    WHEN p_signal IS NULL
      THEN FALSE 
    WHEN p_signal = 'cancel'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attempting cancel of blocking pid %s, query: %s', l.pid, a.query))
    WHEN p_signal = 'terminate'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attempting termination of blocking pid %s, query: %s', l.pid, a.query))
  END AS raised_message,
  l.pid,
  now() AS executed_at,
  a.usename,
  a.client_addr,
  a.xact_start,
  a.state_change,
  a.state,
  a.query,
  FALSE AS reported
FROM pg_locks l
INNER JOIN pg_class c on l.relation = c.oid
INNER JOIN pg_namespace n on c.relnamespace = n.oid
INNER JOIN pg_stat_activity a on l.pid = a.pid
/***
    We need to check if this is an inheritance parent,
    because even a share lock on a child will prevent DDL on parent
***/
LEFT JOIN pg_inherits pi ON pi.inhrelid = c.oid
LEFT JOIN pg_class ipc on ipc.oid = pi.inhparent
LEFT JOIN pg_namespace ipn on ipn.oid = ipc.relnamespace
-- We do not exclude either postgres user or pglogical processes, because we even want to cancel autovac blocks.
-- It should not be possible to contend with pglogical write processes (at least as of pglogical 2.2), because
-- these run single-threaded using the same process that is doing the DDL and already holds any lock it needs
-- on the target table.
WHERE NOT a.pid = pg_backend_pid()
-- both nspname and relname will be an empty string, thus a no-op, if for some reason one or the other
-- is not found on the provider side in pg_event_trigger_ddl_commands().  This is a safety mechanism!
AND ((n.nspname = p_nspname AND c.relname = p_relname)
OR (ipn.nspname = p_nspname AND ipc.relname = p_relname))
AND a.datname = current_database()
AND c.relkind = 'r'
AND l.locktype = 'relation'
ORDER BY l.pid, a.state_change DESC;

END;
$BODY$
SECURITY DEFINER
LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, NAME, NAME) FROM PUBLIC;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.raise_message
(p_log_level TEXT,
p_message TEXT)
RETURNS BOOLEAN 
AS $BODY$
BEGIN

EXECUTE format($$
DO $block$
BEGIN
RAISE %s $pgl_ddl_deploy_msg$%s$pgl_ddl_deploy_msg$;
END$block$;
$$, p_log_level, REPLACE(p_message,'%','%%'));
RETURN TRUE;

END;
$BODY$
LANGUAGE plpgsql VOLATILE;


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
  ,COMMENT
  ,"CREATE RULE"
  ,"CREATE TRIGGER"
  ,"ALTER TRIGGER"}'::TEXT[];
$function$
;




/* pgl_ddl_deploy--1.6--1.7.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

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

    v_rsat_args:=pg_get_function_identity_arguments('pglogical.replication_set_add_table'::REGPROC);


    v_sql:='
    GRANT USAGE ON SCHEMA pglogical TO '||v_rec.rolname||';
    GRANT USAGE ON SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replicate_ddl_command(text, text[]) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replication_set_add_table(' || v_rsat_args || ') TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, name, name) TO '||v_rec.rolname||';
    GRANT INSERT, UPDATE, SELECT ON ALL TABLES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO '||v_rec.rolname||';';




    EXECUTE v_sql;
    RETURN true;
    END LOOP;
RETURN false;
END;
$function$
;


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


/* pgl_ddl_deploy--2.0--2.1.sql */

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


/* pgl_ddl_deploy--2.1--2.2.sql */

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

-- it needs to be modified, so now we drop it to recreate later
DROP VIEW pgl_ddl_deploy.event_trigger_schema;

ELSE

DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT NULL::INT AS id;

END IF;
END$$;

DROP FUNCTION IF EXISTS pgl_ddl_deploy.get_altertable_subcmdinfo(pg_ddl_command);
DROP FUNCTION IF EXISTS pgl_ddl_deploy.get_altertable_subcmdtypes(pg_ddl_command);


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


