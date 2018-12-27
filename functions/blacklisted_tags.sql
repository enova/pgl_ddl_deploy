CREATE OR REPLACE FUNCTION pgl_ddl_deploy.blacklisted_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
        INSERT,
        UPDATE,
        DELETE,
        TRUNCATE,
        ROLLBACK,
        "CREATE EXTENSION",
        "ALTER EXTENSION",
        "DROP EXTENSION"}'::TEXT[];
$function$
;
