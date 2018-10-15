ALTER TABLE pgl_ddl_deploy.set_configs ADD CONSTRAINT repset_tables_restricted_tags CHECK ((NOT include_only_repset_tables) OR (include_only_repset_tables AND pgl_ddl_deploy.standard_repset_only_tags() @> create_tags AND drop_tags IS NULL));

SELECT id, pgl_ddl_deploy.deploy(id) AS deployed
FROM ddl_deploy_to_refresh;

DROP TABLE ddl_deploy_to_refresh;
