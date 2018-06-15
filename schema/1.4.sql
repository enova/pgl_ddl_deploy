SELECT pgl_ddl_deploy.drop_ext_object('FUNCTION','pgl_ddl_deploy.dependency_update');
DROP FUNCTION pgl_ddl_deploy.dependency_update();
SELECT pgl_ddl_deploy.drop_ext_object('VIEW','pgl_ddl_deploy.rep_set_table_wrapper');
DROP VIEW IF EXISTS pgl_ddl_deploy.rep_set_table_wrapper; 
