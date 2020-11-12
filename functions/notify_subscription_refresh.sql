CREATE OR REPLACE FUNCTION pgl_ddl_deploy.notify_subscription_refresh(p_set_name name, p_copy_data boolean DEFAULT TRUE)
 RETURNS BOOLEAN 
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rec RECORD;
    v_sql TEXT;
BEGIN

    IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subpublications && array[p_set_name::text]) THEN
        RAISE EXCEPTION 'No subscription to publication % exists', p_set_name;
    END IF; 

    FOR v_rec IN
        SELECT unnest(subpublications) AS pubname, subname
        FROM pg_subscription
        WHERE subpublications && array[p_set_name::text]
    LOOP

    v_sql = $$ALTER SUBSCRIPTION $$||quote_ident(v_rec.subname)||$$ REFRESH PUBLICATION WITH ( COPY_DATA = '$$||p_copy_data||$$');$$;
    RAISE LOG 'pgl_ddl_deploy executing: %', v_sql;
    EXECUTE v_sql;

    END LOOP;

RETURN TRUE;

END;
$function$
;
