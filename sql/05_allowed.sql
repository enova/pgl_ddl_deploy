SET ROLE test_pgl_ddl_deploy;
SET client_min_messages TO warning;
CREATE TABLE foo(id serial primary key);
SELECT * FROM check_rep_tables;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

ALTER TABLE foo ADD COLUMN bla TEXT;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

INSERT INTO foo (bla) VALUES (1),(2),(3);

DROP TABLE foo CASCADE;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

CREATE SCHEMA foobar;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

CREATE TABLE foobar.foo(id serial primary key);
SELECT * FROM check_rep_tables;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

ALTER TABLE foobar.foo ADD COLUMN bla TEXT;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

INSERT INTO foobar.foo (bla) VALUES (1),(2),(3);

DROP SCHEMA foobar CASCADE;
SELECT * FROM check_rep_tables;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

CREATE FUNCTION foo() RETURNS INT AS
$BODY$
SELECT 1;
$BODY$
LANGUAGE SQL STABLE;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

DROP FUNCTION foo();
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

CREATE VIEW fooview AS
SELECT 1 AS myfield;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

DROP VIEW fooview;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

SELECT * FROM pgl_ddl_deploy.unhandled;
SELECT * FROM pgl_ddl_deploy.exceptions;
