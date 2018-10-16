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

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.undeploy(p_set_config_id int) RETURNS BOOLEAN AS
$BODY$
BEGIN
  RETURN pgl_ddl_deploy.schema_execute(p_set_config_id, 'undeploy_sql');
END;
$BODY$
LANGUAGE plpgsql;
