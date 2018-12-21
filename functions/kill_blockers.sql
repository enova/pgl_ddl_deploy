CREATE OR REPLACE FUNCTION pgl_ddl_deploy.kill_blockers
(p_signal_blocking_subscriber_sessions pgl_ddl_deploy.signals,
p_nspname NAME,
p_relname NAME)
RETURNS TABLE (
signal       pgl_ddl_deploy.signals,
successful   BOOLEAN,
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
BEGIN

RETURN QUERY
SELECT COALESCE(p_signal_blocking_subscriber_sessions,'cancel') AS signal,
  CASE
    WHEN p_signal_blocking_subscriber_sessions IS NULL
      THEN FALSE
    WHEN p_signal_blocking_subscriber_sessions = 'cancel'
      THEN pg_cancel_backend(l.pid)
    WHEN p_signal_blocking_subscriber_sessions = 'terminate'
      THEN pg_terminate_backend(l.pid)
  END AS successful,
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
WHERE NOT a.pid = pg_backend_pid()
-- both nspname and relname will be an empty string, thus a no-op, if for some reason one or the other
-- is not found on the provider side in pg_event_trigger_ddl_commands().  This is a safety mechanism!
AND n.nspname = p_nspname
AND c.relname = p_relname
AND a.datname = current_database()
AND c.relkind = 'r'
AND l.locktype = 'relation';

END;
$BODY$
SECURITY DEFINER
LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers FROM PUBLIC;
