CREATE OR REPLACE FUNCTION pgl_ddl_deploy.queue_ddl_message_type()
 RETURNS "char" 
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT 'Q'::"char";
$function$
;
