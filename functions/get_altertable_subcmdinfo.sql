CREATE OR REPLACE FUNCTION pgl_ddl_deploy.get_altertable_subcmdinfo(pg_ddl_command)
  RETURNS text[] IMMUTABLE STRICT
  AS '$libdir/ddl_deparse', 'get_altertable_subcmdinfo' LANGUAGE C;
