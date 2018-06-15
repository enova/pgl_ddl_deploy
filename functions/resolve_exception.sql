CREATE OR REPLACE FUNCTION pgl_ddl_deploy.resolve_exception(p_exception_id integer, p_notes text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_row_count INT;
BEGIN
  UPDATE pgl_ddl_deploy.exceptions
  SET resolved = TRUE,
    resolved_notes = p_notes
  WHERE id = p_exception_id;

  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RETURN (v_row_count > 0);
END;
$function$
;