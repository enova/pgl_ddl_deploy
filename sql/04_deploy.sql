--These will show different warnings depending on version 
SET client_min_messages = error;
\set VERBOSITY TERSE
/***
No deploy allowed if table would be added to replication
***/
SET ROLE test_pgl_ddl_deploy;
CREATE TABLE foo(id serial primary key);
RESET ROLE;
SELECT pgl_ddl_deploy.deploy('test1');
SET ROLE test_pgl_ddl_deploy;
DROP TABLE foo;
RESET ROLE;

--This should work now
SELECT pgl_ddl_deploy.deploy('test1');
--This should work
SELECT pgl_ddl_deploy.disable('test1');

--This should not work
SET ROLE test_pgl_ddl_deploy;
CREATE TABLE foo(id serial primary key);
RESET ROLE;
SELECT pgl_ddl_deploy.enable('test1');
SET ROLE test_pgl_ddl_deploy;
DROP TABLE foo;
RESET ROLE;

--This should work now
SELECT pgl_ddl_deploy.enable('test1');

--Enable all the rest
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
