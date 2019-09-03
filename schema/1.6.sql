CREATE FUNCTION pgl_ddl_deploy.current_query()
RETURNS TEXT AS
'MODULE_PATHNAME', 'pgl_ddl_deploy_current_query'
LANGUAGE C VOLATILE STRICT;

/*
 * We need to re-deploy the trigger function definitions
 * which will have changed with this extension update. So
 * here we undeploy them, and save which ones we need to 
 * recreate later.
*/
DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT id, pgl_ddl_deploy.undeploy(id) AS undeployed
FROM pgl_ddl_deploy.event_trigger_schema
WHERE is_deployed;
