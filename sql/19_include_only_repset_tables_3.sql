SET client_min_messages = warning;
SET ROLE test_pgl_ddl_deploy;

ALTER TABLE special.foo ADD COLUMN happy TEXT;
ALTER TABLE special.bar ADD COLUMN happier TEXT;

SELECT c.id, c.create_tags, c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
WHERE c.set_name LIKE 'my_special_tables%'
ORDER BY e.id DESC LIMIT 10;

--None of these appear in special tables replication events
DROP TABLE special.foo CASCADE;
DROP TABLE special.bar CASCADE;
DROP SCHEMA special;
