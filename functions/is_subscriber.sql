CREATE OR REPLACE FUNCTION pgl_ddl_deploy.is_subscriber(p_driver pgl_ddl_deploy.driver, p_name TEXT[], p_provider_name NAME = NULL)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN

IF p_driver = 'pglogical' THEN

    RETURN EXISTS (SELECT 1
                  FROM pglogical.subscription s
                  INNER JOIN pglogical.node n
                    ON n.node_id = s.sub_origin
                    AND n.node_name = p_provider_name
                  WHERE sub_replication_sets && p_name);

ELSEIF p_driver = 'native' THEN

    RETURN EXISTS (SELECT 1
                  FROM pg_subscription s
                  WHERE subpublications && p_name);

ELSE

RAISE EXCEPTION 'Unsupported driver specified';

END IF;

END;
$function$
;
