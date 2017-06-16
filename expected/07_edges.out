SET client_min_messages TO warning;
SET ROLE test_pgl_ddl_deploy;

CREATE TABLE foobar.foo (id SERIAL PRIMARY KEY);
CREATE TABLE foo (id SERIAL PRIMARY KEY);

--This is an edge case that currently can't be dealt with well with filtered replication.
ALTER TABLE foobar.foo ADD COLUMN foo_id INT REFERENCES foo(id);
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
