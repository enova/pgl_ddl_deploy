CREATE OR REPLACE FUNCTION pgl_ddl_deploy.enable(p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_deployable BOOLEAN;
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.deployment_check(p_set_name) INTO v_deployable;
  IF v_deployable THEN
    SELECT pgl_ddl_deploy.schema_execute(p_set_name, 'enable_sql') INTO v_result;
    RETURN v_result;
  ELSE
    RETURN v_deployable;
  END IF;
END;
$function$
;