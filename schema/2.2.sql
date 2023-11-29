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
