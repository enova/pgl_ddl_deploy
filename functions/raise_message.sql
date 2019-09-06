CREATE OR REPLACE FUNCTION pgl_ddl_deploy.raise_message
(p_log_level TEXT,
p_message TEXT)
RETURNS BOOLEAN 
AS $BODY$
BEGIN

EXECUTE format($$
DO $block$
BEGIN
RAISE %s $pgl_ddl_deploy_msg$%s$pgl_ddl_deploy_msg$;
END$block$;
$$, p_log_level, REPLACE(p_message,'%','%%'));
RETURN TRUE;

END;
$BODY$
LANGUAGE plpgsql VOLATILE;
