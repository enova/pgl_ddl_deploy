CREATE OR REPLACE FUNCTION pgl_ddl_deploy.unsupported_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
  "CREATE TABLE AS"
  ,"SELECT INTO"
  }'::TEXT[];
$function$
;