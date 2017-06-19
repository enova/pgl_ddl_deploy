SET client_min_messages TO warning;
\set VERBOSITY TERSE

CREATE ROLE test_pgl_ddl_deploy_nopriv;

SET ROLE test_pgl_ddl_deploy_nopriv;

CREATE TEMP TABLE bla (id serial primary key);
DROP TABLE bla;

RESET ROLE;
