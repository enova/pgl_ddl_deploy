SET client_min_messages = warning;

-- We need to eventually test this on a real subscriber
SET search_path TO '';
CREATE SCHEMA bla;

-- We test the subcommand feature with the other repset_table tests

SELECT pgl_ddl_deploy.undeploy(id) FROM pgl_ddl_deploy.set_configs;

CREATE TEMP TABLE repsets AS
WITH new_sets (set_name) AS (
  VALUES ('test_ddl_only'::TEXT)
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

INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, ddl_only_replication)
VALUES ('test_ddl_only','^super.*',false);

-- It is now permitted to have multiple set_configs for same set_name if using ddl_only_replication
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, ddl_only_replication)
VALUES ('test_ddl_only','^duper.*',true);

SET ROLE postgres;
SELECT pgl_ddl_deploy.deploy('test_ddl_only');

-- The difference here is that the latter table is under ddl_only_replication
SET ROLE test_pgl_ddl_deploy;
CREATE SCHEMA super;
CREATE TABLE super.man(id serial primary key);
CREATE SCHEMA duper;
CREATE TABLE duper.man(id serial primary key);

-- Now assume we just want to replicate structure going forward ONLY
ALTER TABLE super.man ADD COLUMN foo text;
ALTER TABLE duper.man ADD COLUMN foo text;

-- No cascade required for second drop because it was not added to replication
DROP TABLE super.man CASCADE;
DROP TABLE duper.man;

SELECT c.set_name, ddl_sql_raw, ddl_sql_sent, c.ddl_only_replication
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY e.id DESC LIMIT 10;
