/* pgl_ddl_deploy--2.0--2.1.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

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

-- This handles potential duplicates with multiple subscriptions to same publisher db.
IF EXISTS (
SELECT NEW.*
INTERSECT
SELECT * FROM pgl_ddl_deploy.queue) THEN
    RETURN NULL;
END IF;

IF NEW.message_type = pgl_ddl_deploy.queue_ddl_message_type() AND
    (pgl_ddl_deploy.override() OR ((SELECT COUNT(1) FROM pg_subscription s
    WHERE subpublications && NEW.pubnames) > 0)) THEN

    -- See https://www.postgresql.org/message-id/CAMa1XUh7ZVnBzORqjJKYOv4_pDSDUCvELRbkF0VtW7pvDW9rZw@mail.gmail.com
    IF NEW.message ~* 'pgl_ddl_deploy.notify_subscription_refresh' THEN
        INSERT INTO pgl_ddl_deploy.subscriber_logs
        (set_name,
         provider_pid,
         provider_node_name,
         provider_set_config_id,
         executed_as_role,
         subscriber_pid,
         executed_at,
         ddl_sql,
         full_ddl_sql,
         succeeded,
         error_message)
        VALUES
        (NEW.pubnames[1],
         NULL,
         NULL,
         NULL,
         current_role,
         pg_backend_pid(),
         current_timestamp,
         NEW.message,
         NEW.message,
         FALSE,
         'Unsupported automated ALTER SUBSCRIPTION ... REFRESH PUBLICATION until bugfix');
    ELSE
        EXECUTE 'SET ROLE '||quote_ident(NEW.role)||';';
        EXECUTE NEW.message::TEXT;
    END IF;

    RETURN NEW;
ELSE
    RETURN NULL; 
END IF;

END;
$function$
;


