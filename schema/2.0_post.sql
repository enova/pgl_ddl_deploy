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
