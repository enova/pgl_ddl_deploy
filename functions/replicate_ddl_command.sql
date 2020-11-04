CREATE OR REPLACE FUNCTION pgl_ddl_deploy.replicate_ddl_command(command text, pubnames text[]) 
 RETURNS BOOLEAN 
 LANGUAGE plpgsql
AS $function$
-- Modeled after pglogical's replicate_ddl_command but in support of native logical replication
BEGIN

-- NOTE: pglogical uses clock_timestamp() to log queued_at times and we do the same here
INSERT INTO pgl_ddl_deploy.queue (queued_at, role, pubnames, message_type, message)
VALUES (clock_timestamp(), current_role, pubnames, pgl_ddl_deploy.queue_ddl_message_type(), to_jsonb(command::text));

RETURN TRUE;

END;
$function$
;
