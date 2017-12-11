SET client_min_messages = warning;

SET ROLE test_pgl_ddl_deploy;

CREATE SCHEMA viewer;

--Should be handled by separate set_config
CREATE TABLE viewer.foo(id int primary key);

--Should be handled by separate set_config
CREATE VIEW viewer.vw_foo AS
SELECT * FROM viewer.foo;

SELECT c.id, c.create_tags, c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
WHERE c.set_name = 'test1'
ORDER BY e.id DESC LIMIT 4;

DROP VIEW viewer.vw_foo;
DROP TABLE viewer.foo CASCADE;
DROP SCHEMA viewer;

SELECT c.id, c.drop_tags, c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
WHERE c.set_name = 'test1'
ORDER BY e.id DESC LIMIT 4;

SELECT * FROM pgl_ddl_deploy.exceptions;
