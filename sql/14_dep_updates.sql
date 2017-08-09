SET client_min_messages TO warning;
DROP VIEW IF EXISTS check_rep_tables;
SELECT pgl_ddl_deploy.dependency_update();
