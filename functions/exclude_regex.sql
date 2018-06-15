CREATE OR REPLACE FUNCTION pgl_ddl_deploy.exclude_regex()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '^(pg_catalog|information_schema|pg_temp|pg_toast|pgl_ddl_deploy|pglogical).*'::TEXT;
$function$
;