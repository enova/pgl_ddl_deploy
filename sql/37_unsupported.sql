SET client_min_messages TO warning;
\set VERBOSITY TERSE
SET ROLE test_pgl_ddl_deploy;

CREATE TABLE foo AS
SELECT 1 AS myfield;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
SELECT set_name, ddl_sql_raw, command_tag, reason FROM pgl_ddl_deploy.unhandled ORDER BY id DESC LIMIT 10;

SELECT 1 AS myfield INTO foobar.foo;
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
SELECT set_name, ddl_sql_raw, command_tag, reason FROM pgl_ddl_deploy.unhandled ORDER BY id DESC LIMIT 10;

DROP TABLE foo;
DROP TABLE foobar.foo;

SELECT * FROM pgl_ddl_deploy.exceptions;
