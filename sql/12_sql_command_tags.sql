SELECT pgl_ddl_deploy.sql_command_tags(NULL);

SELECT pgl_ddl_deploy.sql_command_tags('');

SELECT pgl_ddl_deploy.sql_command_tags('CREATE EXTENSON foo;');

SELECT pgl_ddl_deploy.sql_command_tags('CREATE TABLE foo(); ALTER TABLE foo ADD COLUMN bar text; DROP TABLE foo;');
