CREATE OR REPLACE FUNCTION pgl_ddl_deploy.kill_blockers
(p_signal pgl_ddl_deploy.signals,
p_nspname NAME,
p_relname NAME)
RETURNS TABLE (
signal       pgl_ddl_deploy.signals,
successful   BOOLEAN,
raised_message BOOLEAN,
pid          INT,
executed_at  TIMESTAMPTZ,
usename      NAME,
client_addr  INET,
xact_start   TIMESTAMPTZ,
state_change TIMESTAMPTZ,
state        TEXT,
query        TEXT,
reported     BOOLEAN
)
AS
$BODY$
/****
This function is only called on the subscriber on which we are applying DDL,
when it is blocked and hits the configured lock_timeout.

It is called by the function pgl_ddl_deploy.subscriber_command() only if it hits
lock_timeout and it is configured to send a signal to blocking queries.

It has three main features:
    1. Signal blocking sessions with either cancel or terminate.
    2. Raise a WARNING message to server logs in case of a kill attempt
    3. Return the recordset with details of killed queries for auditing purposes.
****/
BEGIN

RETURN QUERY
SELECT DISTINCT ON (l.pid)
  p_signal AS signal,
  CASE
    WHEN p_signal IS NULL
      THEN FALSE
    WHEN p_signal = 'cancel'
      THEN pg_cancel_backend(l.pid)
    WHEN p_signal = 'terminate'
      THEN pg_terminate_backend(l.pid)
  END AS successful,
  CASE
    WHEN p_signal IS NULL
      THEN FALSE 
    WHEN p_signal = 'cancel'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attempting cancel of blocking pid %s, query: %s', l.pid, a.query))
    WHEN p_signal = 'terminate'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attempting termination of blocking pid %s, query: %s', l.pid, a.query))
  END AS raised_message,
  l.pid,
  now() AS executed_at,
  a.usename,
  a.client_addr,
  a.xact_start,
  a.state_change,
  a.state,
  a.query,
  FALSE AS reported
FROM pg_locks l
INNER JOIN pg_class c on l.relation = c.oid
INNER JOIN pg_namespace n on c.relnamespace = n.oid
INNER JOIN pg_stat_activity a on l.pid = a.pid
/***
    We need to check if this is an inheritance parent,
    because even a share lock on a child will prevent DDL on parent
***/
LEFT JOIN pg_inherits pi ON pi.inhrelid = c.oid
LEFT JOIN pg_class ipc on ipc.oid = pi.inhparent
LEFT JOIN pg_namespace ipn on ipn.oid = ipc.relnamespace
-- We do not exclude either postgres user or pglogical processes, because we even want to cancel autovac blocks.
-- It should not be possible to contend with pglogical write processes (at least as of pglogical 2.2), because
-- these run single-threaded using the same process that is doing the DDL and already holds any lock it needs
-- on the target table.
WHERE NOT a.pid = pg_backend_pid()
-- both nspname and relname will be an empty string, thus a no-op, if for some reason one or the other
-- is not found on the provider side in pg_event_trigger_ddl_commands().  This is a safety mechanism!
AND ((n.nspname = p_nspname AND c.relname = p_relname)
OR (ipn.nspname = p_nspname AND ipc.relname = p_relname))
AND a.datname = current_database()
AND c.relkind = 'r'
AND l.locktype = 'relation'
ORDER BY l.pid, a.state_change DESC;

END;
$BODY$
SECURITY DEFINER
LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, NAME, NAME) FROM PUBLIC;
