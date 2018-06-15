CREATE OR REPLACE FUNCTION pgl_ddl_deploy.schema_execute(p_set_config_id integer, p_field_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rec RECORD;
  v_in_sql TEXT;
  v_out_sql TEXT;
BEGIN
  v_in_sql = $$(SELECT $$||p_field_name||$$
                FROM pgl_ddl_deploy.event_trigger_schema
                WHERE id = $$||p_set_config_id||$$);$$;
  EXECUTE v_in_sql INTO v_out_sql;
  IF v_out_sql IS NULL THEN
    RAISE WARNING 'Failed execution for id % set %', p_set_config_id, (SELECT set_name FROM pgl_ddl_deploy.set_configs WHERE id = p_set_config_id);
    RETURN FALSE;
  ELSE
    EXECUTE v_out_sql;
    RETURN TRUE;
  END IF;
END;
$function$
;ame = '$$||p_set_name||$$');$$;
  EXECUTE v_in_sql INTO v_out_sql;
  IF v_out_sql IS NULL THEN
    RAISE WARNING 'Failed execution for id % set %', v_rec.id, p_set_name;
    RETURN FALSE;
  ELSE
    EXECUTE v_out_sql;
  END IF;

  END LOOP;
  RETURN TRUE;
END;
$function$
;