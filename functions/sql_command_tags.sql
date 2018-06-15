CREATE OR REPLACE FUNCTION pgl_ddl_deploy.sql_command_tags(p_sql text)
 RETURNS text[]
 LANGUAGE c
 STRICT
AS '$libdir/pgl_ddl_deploy', $function$sql_command_tags$function$
;