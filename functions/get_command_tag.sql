CREATE FUNCTION pgl_ddl_deploy.get_command_tag(pg_ddl_command)
  RETURNS text IMMUTABLE STRICT
  AS '$libdir/ddl_deparse', 'get_command_tag' LANGUAGE C;