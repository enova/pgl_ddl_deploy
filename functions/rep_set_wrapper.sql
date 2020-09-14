CREATE OR REPLACE FUNCTION pgl_ddl_deploy.rep_set_wrapper()
 RETURNS TABLE (id OID, name NAME, driver pgl_ddl_deploy.driver)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
/*****
This handles the rename of pglogical.replication_set_relation to pglogical.replication_set_table from version 1 to 2
 */
BEGIN

IF current_setting('server_version_num')::INT < 100000 THEN 
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical') THEN
        RETURN QUERY
        SELECT set_id AS id, set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set rs;

    ELSE
        RAISE EXCEPTION 'pglogical required for version prior to Postgres 10';
    END IF;

ELSE
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
        RETURN QUERY
        SELECT p.oid AS id, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p;

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical') THEN
        RETURN QUERY
        SELECT set_id AS id, set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set rs
        UNION ALL
        SELECT p.oid AS id, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p;
    ELSE
        RAISE EXCEPTION 'Unexpected exception';
    END IF;


END IF;

END;
$function$
;
