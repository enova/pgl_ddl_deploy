CREATE OR REPLACE FUNCTION pgl_ddl_deploy.fail_queued_attempt(p_subscriber_log_id integer, p_error_message text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_new_subscriber_log_id INT;
BEGIN

INSERT INTO pgl_ddl_deploy.subscriber_logs
    (set_name,
    provider_pid,
    subscriber_pid,
    ddl_sql,
    full_ddl_sql,
    origin_subscriber_log_id,
    provider_node_name,
    provider_set_config_id,
    executed_as_role,
    error_message,
    succeeded)
SELECT
    set_name,
    provider_pid,
    pg_backend_pid(),
    ddl_sql,
    full_ddl_sql,
    origin_subscriber_log_id,
    provider_node_name,
    provider_set_config_id,
    executed_as_role,
    p_error_message,
    FALSE
FROM pgl_ddl_deploy.subscriber_logs
WHERE id = p_subscriber_log_id
RETURNING id INTO v_new_subscriber_log_id;

UPDATE pgl_ddl_deploy.subscriber_logs
SET next_subscriber_log_id = v_new_subscriber_log_id
WHERE id = p_subscriber_log_id;

END;
$function$
;