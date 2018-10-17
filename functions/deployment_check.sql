CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_config_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN

RETURN pgl_ddl_deploy.deployment_check_wrapper(p_set_config_id, NULL); 

END;
$function$;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN

RETURN pgl_ddl_deploy.deployment_check_wrapper(NULL, p_set_name); 

END;
$function$;
