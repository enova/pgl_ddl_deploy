CREATE FUNCTION pgl_ddl_deploy.current_query()
RETURNS TEXT AS
'MODULE_PATHNAME', 'pgl_ddl_deploy_current_query'
LANGUAGE C VOLATILE STRICT;
