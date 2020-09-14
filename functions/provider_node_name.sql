CREATE OR REPLACE FUNCTION pgl_ddl_deploy.provider_node_name(p_driver pgl_ddl_deploy.driver)
 RETURNS NAME 
 LANGUAGE plpgsql
AS $function$
DECLARE v_node_name NAME;
BEGIN

IF p_driver = 'pglogical' THEN

    SELECT n.node_name INTO v_node_name
    FROM pglogical.node n
    INNER JOIN pglogical.local_node ln
    USING (node_id);
    RETURN v_node_name;

ELSEIF p_driver = 'native' THEN

    RETURN NULL::NAME; 

ELSE

RAISE EXCEPTION 'Unsupported driver specified';

END IF;

END;
$function$
;
