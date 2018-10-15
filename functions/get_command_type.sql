CREATE FUNCTION pgl_ddl_deploy.get_command_type(pg_ddl_command)
  RETURNS text IMMUTABLE STRICT
  AS '$libdir/ddl_deparse', 'get_command_type' LANGUAGE C;