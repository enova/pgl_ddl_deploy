CREATE OR REPLACE FUNCTION pgl_ddl_deploy.deployment_check(p_set_config_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_set_config_id INT;
  c_include_schema_regex TEXT;
  c_set_name TEXT;
BEGIN

IF NOT EXISTS (SELECT 1 FROM pgl_ddl_deploy.set_configs WHERE id = p_set_config_id) THEN
  RETURN FALSE;
END IF;

--This check only applicable to non-include_only_repset_tables and sets using CREATE TABLE events
--We re-assign set_config_id because we want to know if no records are found, leading to NULL
SELECT id, include_schema_regex, set_name
INTO c_set_config_id, c_include_schema_regex, c_set_name
FROM pgl_ddl_deploy.set_configs
WHERE id = p_set_config_id 
  AND NOT include_only_repset_tables
  AND create_tags && '{"CREATE TABLE"}'::TEXT[];

RETURN pgl_ddl_deploy.deployment_check_count(c_set_config_id, c_set_name, c_include_schema_regex);

END;
$function$
;