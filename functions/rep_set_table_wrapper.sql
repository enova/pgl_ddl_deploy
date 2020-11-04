CREATE OR REPLACE FUNCTION pgl_ddl_deploy.rep_set_table_wrapper()
 RETURNS TABLE (id OID, relid REGCLASS, name NAME, driver pgl_ddl_deploy.driver)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
/*****
This handles the rename of pglogical.replication_set_relation to pglogical.replication_set_table from version 1 to 2
 */
BEGIN

IF current_setting('server_version_num')::INT < 100000 THEN 
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_table') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set_table r
        JOIN pglogical.replication_set rs USING (set_id);

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_relation') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set_relation r
        JOIN pglogical.replication_set rs USING (set_id);

    ELSE
        RAISE EXCEPTION 'No table pglogical.replication_set_relation or pglogical.replication_set_table found';
    END IF;

ELSE
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
        RETURN QUERY
        SELECT p.oid AS id, prrelid::REGCLASS AS relid, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p
        JOIN pg_publication_rel ppr ON ppr.prpubid = p.oid;

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_table') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver
        FROM pglogical.replication_set_table r
        JOIN pglogical.replication_set rs USING (set_id)
        UNION ALL
        SELECT p.oid AS id, prrelid::REGCLASS AS relid, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p
        JOIN pg_publication_rel ppr ON ppr.prpubid = p.oid;

    ELSEIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pglogical' AND tablename = 'replication_set_relation') THEN
        RETURN QUERY
        SELECT r.set_id AS id, r.set_reloid AS relid, rs.set_name AS name, 'pglogical'::pgl_ddl_deploy.driver AS driver 
        FROM pglogical.replication_set_relation r
        JOIN pglogical.replication_set rs USING (set_id)
        UNION ALL
        SELECT p.oid AS id, prrelid::REGCLASS AS relid, pubname AS name, 'native'::pgl_ddl_deploy.driver AS driver
        FROM pg_publication p
        JOIN pg_publication_rel ppr ON ppr.prpubid = p.oid;
    END IF;
END IF;

END;
$function$
;
