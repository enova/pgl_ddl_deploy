SET client_min_messages = warning;
\set VERBOSITY terse
--This should fail due to overlapping tags
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'test1', '.*', TRUE, TRUE, FALSE, '{"CREATE VIEW","ALTER VIEW","CREATE FUNCTION","ALTER FUNCTION"}', '{"DROP VIEW","DROP FUNCTION"}';

--But if we drop these tags from test1, it should work
UPDATE pgl_ddl_deploy.set_configs
SET create_tags = '{ALTER TABLE,CREATE SEQUENCE,ALTER SEQUENCE,CREATE SCHEMA,CREATE TABLE,CREATE TYPE,ALTER TYPE}',
  drop_tags = '{DROP SCHEMA,DROP TABLE,DROP TYPE,DROP SEQUENCE}'
WHERE set_name = 'test1';

--Now this set will only handle these tags
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'test1', '.*', TRUE, TRUE, FALSE, '{"CREATE VIEW","ALTER VIEW","CREATE FUNCTION","ALTER FUNCTION"}', '{"DROP VIEW","DROP FUNCTION"}';

--include_only_repset_tables
DO $$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
CREATE PUBLICATION my_special_tables_1;
CREATE PUBLICATION my_special_tables_2;
ELSE
CREATE TEMP TABLE repsets AS
WITH new_sets (set_name) AS (
  VALUES ('my_special_tables_1'::TEXT),
    ('my_special_tables_2'::TEXT)
)

SELECT pglogical.create_replication_set
(set_name:=s.set_name
,replicate_insert:=TRUE
,replicate_update:=TRUE
,replicate_delete:=TRUE
,replicate_truncate:=TRUE) AS result
FROM new_sets s
WHERE NOT EXISTS (
SELECT 1
FROM pglogical.replication_set
WHERE set_name = s.set_name);

DROP TABLE repsets;
END IF;

END$$;

--Only ALTER TABLE makes sense (and is allowed) with include_only_repset_tables.  So this should fail
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags)
SELECT 'my_special_tables_1', NULL, TRUE, TRUE, TRUE, '{"CREATE TABLE"}';

--This is OK
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'temp_1', NULL, TRUE, TRUE, TRUE, '{"ALTER TABLE"}', NULL;

DELETE FROM pgl_ddl_deploy.set_configs WHERE set_name = 'temp_1';

--This also should fail - no DROP tags at all allowed
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'my_special_tables_1', NULL, TRUE, TRUE, TRUE, '{"ALTER TABLE"}', '{"DROP TABLE"}';

--These both are OK
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'my_special_tables_1', NULL, TRUE, TRUE, TRUE, '{"ALTER TABLE"}', NULL;

INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'my_special_tables_2', NULL, TRUE, TRUE, TRUE, '{"ALTER TABLE"}', NULL; 

--Check we get the defaults we want from the trigger
BEGIN;
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex)
VALUES ('temp_1', '.*');

SELECT create_tags, drop_tags FROM pgl_ddl_deploy.set_configs WHERE set_name = 'temp_1';
ROLLBACK;

BEGIN;
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_only_repset_tables)
VALUES ('temp_1', TRUE);

SELECT create_tags, drop_tags FROM pgl_ddl_deploy.set_configs WHERE set_name = 'temp_1';
ROLLBACK;

--Now deploy again separately
--By set_name:
SELECT pgl_ddl_deploy.deploy('test1');

--By set_config_id
SELECT pgl_ddl_deploy.deploy(id)
FROM pgl_ddl_deploy.set_configs
WHERE set_name = 'test1';
