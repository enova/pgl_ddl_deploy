/* pgl_ddl_deploy--1.3--1.4.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.dependency_update()
 RETURNS void
 LANGUAGE plpgsql
 SET session_replication_role TO 'replica'
AS $function$
/***
Version 1.2 Changes:
- This was causing issues due to event triggers firing.  Disable via session_replication_role.
- We need to re-grant access to the view after dependency_update.

Version 1.4 Changes:
- If this was run, pgl_ddl_deploy.rep_set_table_wrapper was not being properly registered
  as an extension member.
****/
DECLARE
    v_sql TEXT;
    v_rep_set_add_table TEXT;
BEGIN

IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'rep_set_table_wrapper' AND table_schema = 'pgl_ddl_deploy') THEN
    PERFORM pgl_ddl_deploy.drop_ext_object('VIEW','pgl_ddl_deploy.rep_set_table_wrapper');
    DROP VIEW pgl_ddl_deploy.rep_set_table_wrapper;
END IF;
IF (SELECT extversion FROM pg_extension WHERE extname = 'pglogical') ~* '^1.*' THEN

    CREATE VIEW pgl_ddl_deploy.rep_set_table_wrapper AS
    SELECT *
    FROM pglogical.replication_set_relation;

    v_rep_set_add_table = 'pglogical.replication_set_add_table(name, regclass, boolean)';

ELSE

    CREATE VIEW pgl_ddl_deploy.rep_set_table_wrapper AS
    SELECT *
    FROM pglogical.replication_set_table;

    v_rep_set_add_table = 'pglogical.replication_set_add_table(name, regclass, boolean, text[], text)';

END IF;

--View must be re-registered as an extension member.
PERFORM pglogical_ticker.add_ext_object('VIEW','pglogical_ticker.rep_set_table_wrapper');

--Prevent breaking permissions on this table
GRANT SELECT ON TABLE pgl_ddl_deploy.rep_set_table_wrapper TO PUBLIC;

v_sql:=$$
CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_role(p_roleoid oid)
RETURNS BOOLEAN AS $BODY$
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
    GRANT EXECUTE ON FUNCTION $$||v_rep_set_add_table||$$ TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) TO '||v_rec.rolname||';
    GRANT INSERT, UPDATE, SELECT ON ALL TABLES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO '||v_rec.rolname||';';

    EXECUTE v_sql;
    RETURN true;
    END LOOP;
RETURN false;
END;
$BODY$
LANGUAGE plpgsql;
$$;

EXECUTE v_sql;

END;
$function$
;


--This must be done AFTER we update the function def
SELECT pgl_ddl_deploy.dependency_update();


