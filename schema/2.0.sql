/*
 * We need to re-deploy the trigger function definitions
 * which will have changed with this extension update. So
 * here we undeploy them, and save which ones we need to
 * recreate later.
*/
DO $$
BEGIN

IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname = 'pgl_ddl_deploy' AND viewname = 'event_trigger_schema') THEN 

DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT id, pgl_ddl_deploy.undeploy(id) AS undeployed
FROM pgl_ddl_deploy.event_trigger_schema
WHERE is_deployed;

ELSE

DROP TABLE IF EXISTS ddl_deploy_to_refresh;
CREATE TEMP TABLE ddl_deploy_to_refresh AS
SELECT NULL::INT AS id;

END IF;
END$$;

CREATE TYPE pgl_ddl_deploy.driver AS ENUM ('pglogical', 'native');
-- Not possible that any existing config would be native, so:
ALTER TABLE pgl_ddl_deploy.set_configs ADD COLUMN driver pgl_ddl_deploy.driver NOT NULL DEFAULT 'pglogical';
DROP FUNCTION IF EXISTS pgl_ddl_deploy.rep_set_table_wrapper();
DROP FUNCTION IF EXISTS pgl_ddl_deploy.deployment_check_count(integer, text, text);
DROP FUNCTION pgl_ddl_deploy.subscriber_command
(
  p_provider_name NAME,
  p_set_name TEXT[],
  p_nspname NAME,
  p_relname NAME,
  p_ddl_sql_sent TEXT,
  p_full_ddl TEXT,
  p_pid INT,
  p_set_config_id INT,
  p_queue_subscriber_failures BOOLEAN,
  p_signal_blocking_subscriber_sessions pgl_ddl_deploy.signals,
  p_lock_timeout INT,
-- This parameter currently only exists to make testing this function easier
  p_run_anywhere BOOLEAN
);

CREATE TABLE pgl_ddl_deploy.queue(
queued_at timestamp with time zone not null,
role name not null,
pubnames text[],
message_type "char" not null,
message text not null
);
COMMENT ON TABLE pgl_ddl_deploy.queue IS 'Modeled on the pglogical.queue table for native logical replication ddl';
ALTER TABLE pgl_ddl_deploy.queue REPLICA IDENTITY FULL;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.override() RETURNS BOOLEAN AS $BODY$
BEGIN
RETURN FALSE;
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;

-- NOTE - this duplicates execute_queued_ddl.sql function file but is executed here for the upgrade/build path
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

CREATE TRIGGER execute_queued_ddl
BEFORE INSERT ON pgl_ddl_deploy.queue
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.execute_queued_ddl();

-- This must only fire on the replica
ALTER TABLE pgl_ddl_deploy.queue ENABLE REPLICA TRIGGER execute_queued_ddl;
