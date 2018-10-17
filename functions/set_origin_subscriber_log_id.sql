CREATE OR REPLACE FUNCTION pgl_ddl_deploy.set_origin_subscriber_log_id()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
NEW.origin_subscriber_log_id = NEW.id;
RETURN NEW;
END;
$function$
;