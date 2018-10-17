CREATE OR REPLACE FUNCTION pgl_ddl_deploy.retry_all_subscriber_logs()
 RETURNS boolean[]
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_rec RECORD;
    v_result BOOLEAN;
    v_results BOOLEAN[];
BEGIN

FOR v_rec IN
  SELECT
    rq.id
  FROM pgl_ddl_deploy.subscriber_logs rq
  INNER JOIN pgl_ddl_deploy.subscriber_logs rqo ON rqo.id = rq.origin_subscriber_log_id
  WHERE NOT rq.succeeded AND rq.next_subscriber_log_id IS NULL AND NOT rq.retrying
  ORDER BY rqo.executed_at ASC, rqo.origin_subscriber_log_id ASC
LOOP

  SELECT pgl_ddl_deploy.retry_subscriber_log(v_rec.id) INTO v_result;
  v_results = array_append(v_results, v_result);
  IF NOT v_result THEN
    RETURN v_results;
  END IF;

END LOOP;

RETURN v_results;

END;
$function$
;