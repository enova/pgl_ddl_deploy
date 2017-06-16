SET ROLE test_pgl_ddl_deploy;

CREATE TEMP TABLE foo(id SERIAL PRIMARY KEY);
ALTER TABLE foo ADD COLUMN bla TEXT;
DROP TABLE foo;

SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
