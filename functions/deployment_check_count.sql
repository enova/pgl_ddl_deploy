CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check_count(p_set_config_id integer, p_set_name text, p_include_schema_regex text, p_driver pgl_ddl_deploy.driver)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
BEGIN

--If the check is not applicable, pass it
IF p_set_config_id IS NULL THEN
  RETURN TRUE;
END IF;

SELECT COUNT(1)
INTO v_count
FROM pg_namespace n
  INNER JOIN pg_class c ON n.oid = c.relnamespace
    AND c.relpersistence = 'p'
  WHERE n.nspname ~* p_include_schema_regex
    AND n.nspname !~* c_exclude_always
    AND EXISTS (SELECT 1
    FROM pg_index i
    WHERE i.indrelid = c.oid
      AND i.indisprimary)
    AND NOT EXISTS
    (SELECT 1
    FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
    WHERE rsr.name = p_set_name
      AND rsr.relid = c.oid
      AND rsr.driver = p_driver);

IF v_count > 0 THEN
  RAISE WARNING $ERR$
  Deployment of auto-replication for id % set_name % failed
  because % tables are already queued to be added to replication
  based on your configuration.  These tables need to be added to
  replication manually and synced, otherwise change your configuration.
  Debug query: %$ERR$,
    p_set_config_id,
    p_set_name,
    v_count,
    $SQL$
    SELECT n.nspname, c.relname
    FROM pg_namespace n
      INNER JOIN pg_class c ON n.oid = c.relnamespace
        AND c.relpersistence = 'p'
      WHERE n.nspname ~* '$SQL$||p_include_schema_regex||$SQL$'
        AND n.nspname !~* '$SQL$||c_exclude_always||$SQL$'
        AND EXISTS (SELECT 1
        FROM pg_index i
        WHERE i.indrelid = c.oid
          AND i.indisprimary)
        AND NOT EXISTS
        (SELECT 1
        FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
        WHERE rsr.name = '$SQL$||p_set_name||$SQL$'
          AND rsr.relid = c.oid
          AND rsr.driver = (SELECT driver FROM pgl_ddl_deploy.set_configs WHERE set_name = '$SQL$||p_set_name||$SQL$'));
    $SQL$;
    RETURN FALSE;
END IF;

RETURN TRUE;

END;
$function$
;
