CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_role(p_roleoid oid)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
/******
Assuming roles doing DDL are not superusers, this function grants needed privileges
to run through the pgl_ddl_deploy DDL deployment.
This needs to be run on BOTH provider and subscriber.
******/
DECLARE
    v_rec RECORD;
    v_sql TEXT;
BEGIN

    FOR v_rec IN
        SELECT quote_ident(rolname) AS rolname FROM pg_roles WHERE oid = p_roleoid
    LOOP

    v_sql:='
    GRANT USAGE ON SCHEMA pglogical TO '||v_rec.rolname||';
    GRANT USAGE ON SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replicate_ddl_command(text, text[]) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replication_set_add_table(name, regclass, boolean, text[], text) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) TO '||v_rec.rolname||';
    GRANT INSERT, UPDATE, SELECT ON ALL TABLES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO '||v_rec.rolname||';';

    EXECUTE v_sql;
    RETURN true;
    END LOOP;
RETURN false;
END;
$function$
;