CREATE OR REPLACE FUNCTION pgl_ddl_deploy.execute_queued_ddl()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN

/***
Native logical replication does not support row filtering, so as a result,
we need to do processing downstream to ensure we only process rows we care about.

For example, if we propagate some DDL to system 1 and some other to system 2,
all rows will still come through this trigger.  We filter out rows based on
matching pubnames with pg_subscription.subpublications

If a row arrives here (the subscriber), it must mean that it was propagated
***/

IF NEW.message_type = pgl_ddl_deploy.queue_ddl_message_type() AND
    (SELECT COUNT(1) FROM pg_subscription s
    WHERE subpublications && NEW.pubnames) > 0 THEN
    
    EXECUTE 'SET ROLE '||quote_ident(NEW.role)||';';
    EXECUTE NEW.message::TEXT;

    RETURN NEW;
ELSE
    RETURN NULL; 
END IF;

END;
$function$
;
