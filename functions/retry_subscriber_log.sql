CREATE OR REPLACE FUNCTION pgl_ddl_deploy.retry_subscriber_log(p_subscriber_log_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_sql TEXT;
    v_role TEXT;
    v_return BOOLEAN;
BEGIN
    IF (SELECT retrying FROM pgl_ddl_deploy.subscriber_logs
        WHERE id = p_subscriber_log_id) = TRUE THEN
      RAISE WARNING 'This subscriber_log_id is already executing.  No action will be taken.';
      RETURN FALSE;
    END IF;

    SELECT full_ddl_sql, executed_as_role
    INTO v_sql, v_role
    FROM pgl_ddl_deploy.subscriber_logs
    WHERE id = p_subscriber_log_id;

    UPDATE pgl_ddl_deploy.subscriber_logs
    SET retrying = TRUE
    WHERE id = p_subscriber_log_id;

  BEGIN
      /**
      This needs to be a DO block because currently,the final SQL sent to subscriber is always within a DO block
       */
      v_sql = $$
      DO $RETRY$
      BEGIN

      SET ROLE $$||quote_ident(v_role)||$$;

      $$||v_sql||$$

      END$RETRY$;
      $$;
      EXECUTE v_sql;
      RESET ROLE;

      WITH success AS (
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
          TRUE
      FROM pgl_ddl_deploy.subscriber_logs
      WHERE id = p_subscriber_log_id
      RETURNING *
      )

      UPDATE pgl_ddl_deploy.subscriber_logs
      SET next_subscriber_log_id = (SELECT id FROM success)
      WHERE id = p_subscriber_log_id;

      v_return = TRUE;

  EXCEPTION WHEN OTHERS THEN
      PERFORM pgl_ddl_deploy.fail_queued_attempt(p_subscriber_log_id, SQLERRM);
      v_return = FALSE;
  END;

  UPDATE pgl_ddl_deploy.subscriber_logs
  SET retrying = FALSE
  WHERE id = p_subscriber_log_id;

  RETURN v_return;

END;
$function$
;