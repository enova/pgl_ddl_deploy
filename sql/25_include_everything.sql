SET client_min_messages TO warning;

INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements)
VALUES ('test1','.*',true, true);

-- It's generally good to use queue_subscriber_failures with include_everything, so a bogus grant won't break replication on subscriber
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_everything, queue_subscriber_failures, create_tags)
VALUES ('test1',true, true, '{GRANT,REVOKE}');

SELECT pgl_ddl_deploy.deploy(id) FROM pgl_ddl_deploy.set_configs WHERE set_name = 'test1';

SET ROLE test_pgl_ddl_deploy;
CREATE TABLE foo(id serial primary key, bla int);
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

GRANT SELECT ON foo TO PUBLIC; 
SELECT c.set_name, ddl_sql_raw, ddl_sql_sent, c.include_everything
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY e.id DESC LIMIT 10;

INSERT INTO foo (bla) VALUES (1),(2),(3);

REVOKE INSERT ON foo FROM PUBLIC;
DROP TABLE foo CASCADE;
SELECT c.set_name, ddl_sql_raw, ddl_sql_sent, c.include_everything
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY e.id DESC LIMIT 10;

SELECT * FROM pgl_ddl_deploy.unhandled;
SELECT * FROM pgl_ddl_deploy.exceptions;
