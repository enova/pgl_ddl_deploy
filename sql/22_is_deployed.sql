SET client_min_messages TO warning;

--Test what is_deployed shows (introduced in 1.3)
SELECT set_name, is_deployed FROM pgl_ddl_deploy.event_trigger_schema ORDER BY id;
SELECT pgl_ddl_deploy.undeploy(id) FROM pgl_ddl_deploy.set_configs;
SELECT set_name, is_deployed FROM pgl_ddl_deploy.event_trigger_schema ORDER BY id;

--Nothing should replicate this
CREATE TABLE foobar (id serial primary key);
DROP TABLE foobar;

SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

--Re-deploy and check again what shows as deployed
SELECT pgl_ddl_deploy.deploy(id) FROM pgl_ddl_deploy.set_configs;
SELECT set_name, is_deployed FROM pgl_ddl_deploy.event_trigger_schema ORDER BY id;

CREATE TABLE foobar (id serial primary key);
DROP TABLE foobar CASCADE;

SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;
