CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deploy(p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
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
$function$
;

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
