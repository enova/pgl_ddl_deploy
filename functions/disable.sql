CREATE OR REPLACE FUNCTION pgl_ddl_deploy.disable(p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_result BOOLEAN;
BEGIN
  SELECT pgl_ddl_deploy.schema_execute(p_set_name, 'disable_sql') INTO v_result;
  RETURN v_result;
END;
$function$
;