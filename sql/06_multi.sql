SET log_min_messages TO warning;
SET ROLE test_pgl_ddl_deploy;
CREATE SCHEMA foobar;

--This should never be allowed
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "CREATE TABLE foo(id int primary key); INSERT INTO foo (id) VALUES (1),(2),(3); DROP TABLE foo;"
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "CREATE TABLE foobar.foo(id int primary key); INSERT INTO foobar.foo (id) VALUES (1),(2),(3); DROP TABLE foobar.foo;"
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
SELECT set_name, ddl_sql, command_tag, reason FROM pgl_ddl_deploy.unhandled ORDER BY id DESC LIMIT 10;

--This should be allowed by some configurations, and others not
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; CREATE TABLE foo(id int primary key); COMMIT;"
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; CREATE TABLE foobar.foo(id int primary key); COMMIT;"
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
SELECT set_name, ddl_sql, command_tag, reason FROM pgl_ddl_deploy.unhandled ORDER BY id DESC LIMIT 10;

--Run all commands through cli to avoid permissions issues
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "DROP TABLE foo CASCADE;"
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "DROP TABLE foobar.foo CASCADE;"

--This should be allowed by some configurations, and others not
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "CREATE TABLE foo(id int primary key); DROP TABLE foo CASCADE;"
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "CREATE TABLE foobar.foo(id int primary key); DROP TABLE foobar.foo CASCADE;"
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
SELECT set_name, ddl_sql, command_tag, reason FROM pgl_ddl_deploy.unhandled ORDER BY id DESC LIMIT 10;

\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "CREATE TABLE foo(id int primary key);"
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "CREATE TABLE foobar.foo(id int primary key);"

--This is an edge case that currently can't be dealt with well with targeted replication.
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "ALTER TABLE foobar.foo ADD COLUMN foo_id INT REFERENCES foo(id);"
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

--This should be allowed by some but not others
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "DROP TABLE foo, foobar.foo CASCADE;"
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
SELECT set_name, ddl_sql, command_tag, reason FROM pgl_ddl_deploy.unhandled ORDER BY id DESC LIMIT 10;

SELECT * FROM pgl_ddl_deploy.exceptions;
