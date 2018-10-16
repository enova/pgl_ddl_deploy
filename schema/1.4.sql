DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT id, pgl_ddl_deploy.undeploy(id) AS undeployed
FROM pgl_ddl_deploy.event_trigger_schema
WHERE is_deployed;

SELECT pgl_ddl_deploy.drop_ext_object('FUNCTION','pgl_ddl_deploy.dependency_update');
DROP FUNCTION pgl_ddl_deploy.dependency_update();
SELECT pgl_ddl_deploy.drop_ext_object('VIEW','pgl_ddl_deploy.rep_set_table_wrapper');
DROP VIEW IF EXISTS pgl_ddl_deploy.rep_set_table_wrapper; 

ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN exclude_alter_table_subcommands TEXT[];

ALTER TABLE pgl_ddl_deploy.set_configs DROP CONSTRAINT repset_tables_only_alter_table;

SELECT pg_catalog.pg_extension_config_dump('pgl_ddl_deploy.set_configs_id_seq', '');

ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN ddl_only_replication BOOLEAN NOT NULL DEFAULT FALSE;
