--****NOTE*** this file drops the whole extension and all previous test setup.
--If adding new tests, it is best to keep this file as the last test before cleanup.
SET client_min_messages = warning;

--Some day, we should regress with multiple databases.  There are examples of this in pglogical code base
--For now, we will mock the subscriber behavior, which is less than ideal, because it misses testing execution
--on subscriber

DROP EXTENSION pgl_ddl_deploy CASCADE;

-- This test has been rewritten and presently exists for historical reasons and to maintain configuration
CREATE EXTENSION pgl_ddl_deploy;

--These are the same sets as in the new_set_behavior.sql
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'my_special_tables_1', NULL, TRUE, TRUE, TRUE, '{"ALTER TABLE"}', NULL;

INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements, include_only_repset_tables, create_tags, drop_tags)
SELECT 'my_special_tables_2', NULL, TRUE, TRUE, TRUE, '{"ALTER TABLE"}', NULL; 

--One include_schema_regex one that should be unchanged
CREATE TEMP TABLE repsets AS
WITH new_sets (set_name) AS (
  VALUES ('testspecial'::TEXT)
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

INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements)
VALUES ('testspecial','^special$',true, true);
SELECT pgl_ddl_deploy.deploy('testspecial');

--These kinds of repsets will not replicate CREATE events, only ALTER TABLE, so deploy after CREATE
--We assume schema will be copied to subscriber separately
CREATE SCHEMA special;
CREATE TABLE special.foo (id serial primary key, foo text, bar text);
CREATE TABLE special.bar (id serial primary key, super text, man text);

SELECT pgl_ddl_deploy.add_table_to_replication(
  p_driver:=driver
  ,p_set_name:=name
  ,p_relation:='special.foo'::REGCLASS)
FROM pgl_ddl_deploy.rep_set_wrapper()
WHERE name = 'my_special_tables_1';

SELECT pgl_ddl_deploy.add_table_to_replication(
  p_driver:=driver
  ,p_set_name:=name
  ,p_relation:='special.bar'::REGCLASS)
FROM pgl_ddl_deploy.rep_set_wrapper()
WHERE name = 'my_special_tables_2';

--Deploy by set_name
SELECT pgl_ddl_deploy.deploy('my_special_tables_1');
SELECT pgl_ddl_deploy.deploy('my_special_tables_2');

