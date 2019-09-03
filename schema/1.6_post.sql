-- Now re-deploy event triggers and functions
SELECT id, pgl_ddl_deploy.deploy(id) AS deployed
FROM ddl_deploy_to_refresh;

DROP TABLE ddl_deploy_to_refresh;
DROP TABLE IF EXISTS tmp_objs;
