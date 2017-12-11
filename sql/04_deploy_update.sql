--This will show different warnings depending on if we are actually updating to new version or not
SET client_min_messages = error;

ALTER EXTENSION pgl_ddl_deploy UPDATE;
SELECT pgl_ddl_deploy.deploy('test1');
DO $$
DECLARE v_rec RECORD;
BEGIN

FOR v_rec IN
    SELECT set_name
    FROM pglogical.replication_set
    WHERE set_name LIKE 'test%' AND set_name <> 'test1'
    ORDER BY set_name
LOOP

PERFORM pgl_ddl_deploy.deploy(v_rec.set_name);

END LOOP;

END$$;

--Now that we are on highest version, ensure WARNING shows
SELECT pglogical.create_replication_set
(set_name:='testtemp'
,replicate_insert:=TRUE
,replicate_update:=TRUE
,replicate_delete:=TRUE
,replicate_truncate:=TRUE)
INTO TEMP repset;

DROP TABLE repset;

SET client_min_messages = warning;
BEGIN;
INSERT INTO pgl_ddl_deploy.set_configs (id, set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements)
VALUES (999, 'testtemp','.*',true, true);

CREATE TABLE break(id serial primary key);
SELECT pgl_ddl_deploy.deploy('testtemp');

ROLLBACK;
