CREATE OR REPLACE FUNCTION pgl_ddl_deploy.toggle_ext_object(p_type text, p_full_obj_name text, p_toggle text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  c_valid_types TEXT[] = ARRAY['EVENT TRIGGER','FUNCTION','VIEW'];
  c_valid_toggles TEXT[] = ARRAY['ADD','DROP'];
BEGIN

IF NOT (SELECT ARRAY[p_type] && c_valid_types) THEN
  RAISE EXCEPTION 'Must pass one of % as 1st arg.', array_to_string(c_valid_types);
END IF;

IF NOT (SELECT ARRAY[p_toggle] && c_valid_toggles) THEN
  RAISE EXCEPTION 'Must pass one of % as 3rd arg.', array_to_string(c_valid_toggles);
END IF;

EXECUTE 'ALTER EXTENSION pgl_ddl_deploy '||p_toggle||' '||p_type||' '||p_full_obj_name;

EXCEPTION
  WHEN undefined_function THEN
    RETURN;
  WHEN undefined_object THEN
    RETURN;
  WHEN object_not_in_prerequisite_state THEN
    RETURN;
END;
$function$
;