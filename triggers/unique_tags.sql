CREATE TRIGGER unique_tags
AFTER INSERT OR UPDATE ON pgl_ddl_deploy.set_configs
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.unique_tags();
