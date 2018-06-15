CREATE OR REPLACE FUNCTION pgl_ddl_deploy.lock_safe_executor(p_sql text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
SET lock_timeout TO '10ms';
LOOP
  BEGIN
    EXECUTE p_sql;
    EXIT;
  EXCEPTION
    WHEN lock_not_available
      THEN RAISE WARNING 'Could not obtain immediate lock for SQL %, retrying', p_sql;
      PERFORM pg_sleep(3);
    WHEN OTHERS THEN
      RAISE;
  END;
END LOOP;
END;
$function$
;