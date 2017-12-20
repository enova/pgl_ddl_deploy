SET client_min_messages = warning;

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
