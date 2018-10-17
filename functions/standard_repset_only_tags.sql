CREATE OR REPLACE FUNCTION pgl_ddl_deploy.standard_repset_only_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
  "ALTER TABLE"
  ,COMMENT}'::TEXT[];
$function$
;