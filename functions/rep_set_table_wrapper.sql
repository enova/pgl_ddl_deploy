CREATE OR REPLACE FUNCTION pgl_ddl_deploy.rep_set_table_wrapper()
 RETURNS TABLE (set_id OID, set_reloid REGCLASS)
 LANGUAGE plpgsql
AS $function$
/*****
This handles the rename of pglogical.replication_set_relation to pglogical.replication_set_table from version 1 to 2
 */
BEGIN

IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_table') THEN
    RETURN QUERY
    SELECT r.set_id, r.set_reloid 
    FROM pglogical.replication_set_table r;

ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_relation') THEN
    RETURN QUERY
    SELECT r.set_id, r.set_reloid 
    FROM pglogical.replication_set_relation r;

ELSE
    RAISE EXCEPTION 'No table pglogical.replication_set_relation or pglogical.replication_set_table found';
END IF;

END;
$function$
;
