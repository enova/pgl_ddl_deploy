SET ROLE test_pgl_ddl_deploy;
SET client_min_messages TO warning;

BEGIN;

/***
In default schema
**/
CREATE TABLE foo(id serial primary key);
SELECT * FROM check_rep_tables();
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

ALTER TABLE foo ADD COLUMN bla TEXT;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

INSERT INTO foo (bla) VALUES (1),(2),(3);

DROP TABLE foo CASCADE;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

CREATE TABLE foobar.foo(id serial primary key);
SELECT * FROM check_rep_tables();
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

ALTER TABLE foobar.foo ADD COLUMN bla TEXT;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

INSERT INTO foobar.foo (bla) VALUES (1),(2),(3);

DROP TABLE foobar.foo CASCADE;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

COMMIT;

SELECT * FROM pgl_ddl_deploy.exceptions;
