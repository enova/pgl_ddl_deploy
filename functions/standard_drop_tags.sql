CREATE OR REPLACE FUNCTION pgl_ddl_deploy.standard_drop_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
  "DROP SCHEMA"
  ,"DROP TABLE"
  ,"DROP FUNCTION"
  ,"DROP TYPE"
  ,"DROP VIEW"
  ,"DROP SEQUENCE"  
  }'::TEXT[];
$function$
;