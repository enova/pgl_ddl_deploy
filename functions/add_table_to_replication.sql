CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_table_to_replication(p_driver pgl_ddl_deploy.driver, p_set_name name, p_relation regclass, p_synchronize_data boolean DEFAULT false)
 RETURNS BOOLEAN 
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_schema NAME;
    v_table NAME;
    v_result BOOLEAN = false;
BEGIN
IF p_driver = 'pglogical' THEN

    SELECT pglogical.replication_set_add_table(
            set_name:=p_set_name
            ,relation:=p_relation
            ,synchronize_data:=p_synchronize_data
          ) INTO v_result;

ELSEIF p_driver = 'native' THEN

    SELECT nspname, relname INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_relation::OID;

    EXECUTE 'ALTER PUBLICATION '||quote_ident(p_set_name)||' ADD TABLE '||quote_ident(v_schema)||'.'||quote_ident(v_table)||';';
    
    -- We use true to synchronize data here, not taking the value from p_synchronize_data.  This is because of the different way
    -- that native logical works, and that changes are not queued from the time of the table being added to replication.  Thus, we
    -- by default WILL use COPY_DATA = true

    -- This needs to be in a DO block currently because of how the DDL is processed on the subscriber.
    PERFORM pgl_ddl_deploy.replicate_ddl_command($$DO $AUTO_REPLICATE_BLOCK$
    BEGIN
    PERFORM pgl_ddl_deploy.notify_subscription_refresh('$$||p_set_name||$$', true);
    END$AUTO_REPLICATE_BLOCK$;$$, array[p_set_name]);
    v_result = true;

ELSE

RAISE EXCEPTION 'Unsupported driver specified';

END IF;

RETURN v_result;

END;
$function$
;
