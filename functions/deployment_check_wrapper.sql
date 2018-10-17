CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check_wrapper(p_set_config_id integer, p_set_name text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_set_config_id INT;
  c_include_schema_regex TEXT;
  v_include_only_repset_tables BOOLEAN;
  v_ddl_only_replication BOOLEAN;
  c_set_name TEXT;
BEGIN

IF p_set_config_id IS NOT NULL AND p_set_name IS NOT NULL THEN
    RAISE EXCEPTION 'This function can only be called with one of the two arguments set.';
END IF;

IF NOT EXISTS (SELECT 1 FROM pgl_ddl_deploy.set_configs WHERE ((p_set_name is null and id = p_set_config_id) OR (p_set_config_id is null and set_name = p_set_name))) THEN
  RETURN FALSE;                                               
END IF;

/***
  This check is only applicable to NON-include_only_repset_tables and sets using CREATE TABLE events.
  It is also bypassed if ddl_only_replication is true in which we never auto-add tables to replication.
  We re-assign set_config_id because we want to know if no records are found, leading to NULL
*/
SELECT id, include_schema_regex, set_name, include_only_repset_tables, ddl_only_replication
INTO c_set_config_id, c_include_schema_regex, c_set_name, v_include_only_repset_tables, v_ddl_only_replication
FROM pgl_ddl_deploy.set_configs
WHERE ((p_set_name is null and id = p_set_config_id)
  OR (p_set_config_id is null and set_name = p_set_name))
  AND create_tags && '{"CREATE TABLE"}'::TEXT[];

IF v_include_only_repset_tables OR v_ddl_only_replication THEN
    RETURN TRUE;
END IF;

RETURN pgl_ddl_deploy.deployment_check_count(c_set_config_id, c_set_name, c_include_schema_regex);

END;
$function$;
