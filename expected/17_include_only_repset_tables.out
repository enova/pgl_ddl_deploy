SET client_min_messages = warning;

SET ROLE test_pgl_ddl_deploy;

--These kinds of repsets will not replicate CREATE events, only ALTER TABLE, so deploy after CREATE
--We assume schema will be copied to subscriber separately
CREATE SCHEMA special;
CREATE TABLE special.foo (id serial primary key, foo text, bar text);
CREATE TABLE special.bar (id serial primary key, super text, man text);

SELECT pglogical.replication_set_add_table(
  set_name:='my_special_tables_1'
  ,relation:='special.foo'::REGCLASS);

SELECT pglogical.replication_set_add_table(
  set_name:='my_special_tables_2'
  ,relation:='special.bar'::REGCLASS);

--Deploy by set_name
SELECT pgl_ddl_deploy.deploy('my_special_tables_1');
SELECT pgl_ddl_deploy.deploy('my_special_tables_2');

--Deploy by id
SELECT pgl_ddl_deploy.deploy(id)
FROM pgl_ddl_deploy.set_configs
WHERE set_name = 'my_special_tables_1';

SELECT pgl_ddl_deploy.deploy(id)
FROM pgl_ddl_deploy.set_configs
WHERE set_name = 'my_special_tables_2';

ALTER TABLE special.foo ADD COLUMN happy TEXT;
ALTER TABLE special.bar ADD COLUMN happier TEXT;

SELECT c.create_tags, c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY id DESC LIMIT 10;