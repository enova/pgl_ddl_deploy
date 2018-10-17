CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_ext_object(p_type text, p_full_obj_name text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
PERFORM pgl_ddl_deploy.toggle_ext_object(p_type, p_full_obj_name, 'ADD');
END;
$function$
;