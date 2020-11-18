DO $$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
EXECUTE $sql$
CREATE PUBLICATION test1;
CREATE PUBLICATION test2;
CREATE PUBLICATION test3;
CREATE PUBLICATION test4;
CREATE PUBLICATION test5;
CREATE PUBLICATION test6;
CREATE PUBLICATION test7;
CREATE PUBLICATION test8;$sql$;
ELSE
CREATE TEMP TABLE foonode AS SELECT pglogical.create_node('test','host=localhost');
DROP TABLE foonode;

CREATE TEMP TABLE repsets AS
WITH sets AS (
SELECT 'test'||generate_series AS set_name
FROM generate_series(1,8)
)

SELECT pglogical.create_replication_set
(set_name:=s.set_name
,replicate_insert:=TRUE
,replicate_update:=TRUE
,replicate_delete:=TRUE
,replicate_truncate:=TRUE) AS result
FROM sets s;

DROP TABLE repsets;
END IF;

END$$;
CREATE ROLE test_pgl_ddl_deploy LOGIN;
GRANT CREATE ON DATABASE contrib_regression TO test_pgl_ddl_deploy;

SELECT pgl_ddl_deploy.add_role(oid) FROM pg_roles WHERE rolname = 'test_pgl_ddl_deploy';

SET ROLE test_pgl_ddl_deploy;

CREATE FUNCTION check_rep_tables() RETURNS TABLE (set_name TEXT, table_name TEXT)
AS 
$BODY$
BEGIN

-- Handle change from view to function rep_set_table_wrapper
IF (SELECT extversion FROM pg_extension WHERE extname = 'pgl_ddl_deploy') = ANY('{1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7}'::text[]) THEN
    RETURN QUERY EXECUTE $$
    SELECT set_name::TEXT, set_reloid::TEXT AS table_name
    FROM pgl_ddl_deploy.rep_set_table_wrapper rsr
    INNER JOIN pglogical.replication_set rs USING (set_id)
    ORDER BY set_name::TEXT, set_reloid::TEXT;$$;
ELSE
    RETURN QUERY EXECUTE $$
    SELECT name::TEXT AS set_name, relid::regclass::TEXT AS table_name
    FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
    WHERE relid::regclass::TEXT <> 'pgl_ddl_deploy.queue'
    ORDER BY name::TEXT, relid::TEXT;$$;
END IF;

END;
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION all_queues() RETURNS TABLE (queued_at timestamp with time zone,
role name,
pubnames text[],
message_type "char",
-- we use json here to provide test output consistency whether native or pglogical
message json)
AS
$BODY$
BEGIN
IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
    RETURN QUERY EXECUTE $$
    SELECT queued_at,
    role,
    replication_sets AS pubnames,
    message_type,
    message
    FROM pglogical.queue
    UNION ALL
    SELECT queued_at,
    role,
    pubnames,
    message_type,
    to_json(message)
    FROM pgl_ddl_deploy.queue;$$;
ELSE
    RETURN QUERY EXECUTE $$
    SELECT queued_at,
    role,
    pubnames,
    message_type,
    to_json(message) AS message
    FROM pgl_ddl_deploy.queue;
    $$;
END IF;
END;
$BODY$
LANGUAGE plpgsql;
