SET client_min_messages TO warning;
\set VERBOSITY TERSE

SET SESSION_REPLICATION_ROLE TO REPLICA;

CREATE TABLE i_want_to_ignore_evts (id serial primary key);
DROP TABLE i_want_to_ignore_evts;

SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

RESET SESSION_REPLICATION_ROLE;
