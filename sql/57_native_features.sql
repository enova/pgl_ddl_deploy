
SET client_min_messages = warning;
DO $$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
SET session_replication_role TO replica;
ELSE
CREATE EXTENSION pglogical;
END IF;

END$$;
CREATE EXTENSION pgl_ddl_deploy;

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.override() RETURNS BOOLEAN AS $BODY$
BEGIN
RETURN TRUE;
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;

INSERT INTO pgl_ddl_deploy.queue (queued_at,role,pubnames,message_type,message)
VALUES (now(),current_role,'{mock}'::TEXT[],pgl_ddl_deploy.queue_ddl_message_type(),'CREATE TABLE nativerox(id int)');

INSERT INTO pgl_ddl_deploy.queue (queued_at,role,pubnames,message_type,message)
VALUES (now(),current_role,'{mock}'::TEXT[],pgl_ddl_deploy.queue_ddl_message_type(),'ALTER TABLE nativerox ADD COLUMN bar text;');

INSERT INTO pgl_ddl_deploy.queue (queued_at,role,pubnames,message_type,message)
VALUES (now(),current_role,'{mock}'::TEXT[],pgl_ddl_deploy.queue_ddl_message_type(),$$SELECT pgl_ddl_deploy.notify_subscription_refresh('mock', true);$$);

CREATE FUNCTION verify_count(ct int, expected int) RETURNS BOOLEAN AS $BODY$
BEGIN

RAISE LOG 'ct: %', ct;
IF ct != expected THEN
    RAISE EXCEPTION 'Count % does not match expected count of %', ct, expected;
END IF;

RETURN TRUE;

END$BODY$
LANGUAGE plpgsql;

DO $$
DECLARE v_ct INT;
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
    SELECT COUNT(1) INTO v_ct FROM information_schema.columns WHERE table_name = 'nativerox';
    PERFORM verify_count(v_ct, 2);
    SELECT COUNT(1) INTO v_ct FROM pgl_ddl_deploy.subscriber_logs;
    PERFORM verify_count(v_ct, 1);
    PERFORM pgl_ddl_deploy.retry_all_subscriber_logs(); 
    SELECT (SELECT COUNT(1) FROM pgl_ddl_deploy.subscriber_logs WHERE NOT succeeded) +
    (SELECT COUNT(1) FROM pgl_ddl_deploy.subscriber_logs WHERE error_message ~* 'No subscription to publication mock exists') INTO v_ct; 
    PERFORM verify_count(v_ct, 3);
    -- test for duplicate avoidance with multiple subscriptions
    SELECT COUNT(1) INTO v_ct FROM pgl_ddl_deploy.queue;
    PERFORM verify_count(v_ct, 3);
    SET session_replication_role TO replica;
    INSERT INTO pgl_ddl_deploy.queue SELECT * FROM pgl_ddl_deploy.queue;
    SELECT COUNT(1) INTO v_ct FROM pgl_ddl_deploy.queue;
    PERFORM verify_count(v_ct, 3);
    RESET session_replication_role;
ELSE
    SELECT COUNT(1) INTO v_ct FROM pgl_ddl_deploy.subscriber_logs;
    PERFORM verify_count(v_ct, 0);
END IF;

END$$;

