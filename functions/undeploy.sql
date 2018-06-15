CREATE OR REPLACE FUNCTION pgl_ddl_deploy.undeploy(p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN pgl_ddl_deploy.schema_execute(p_set_name, 'undeploy_sql');
END;
$function$
;
$function$
;