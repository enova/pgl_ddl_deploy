ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN include_everything
  BOOLEAN NOT NULL DEFAULT FALSE;

-- Now we have 3 configuration types
ALTER TABLE pgl_ddl_deploy.set_configs
  DROP CONSTRAINT repset_tables_or_regex_inclusion;

-- Only allow one of them to be chosen
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT single_configuration_type
  CHECK
  ((include_schema_regex IS NOT NULL
   AND NOT include_only_repset_tables)
   OR
   (include_only_repset_tables
    AND include_schema_regex IS NULL)
   OR
   (include_everything
    AND NOT include_only_repset_tables
    AND include_schema_regex IS NULL));

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT ddl_only_restrictions
  CHECK (NOT (ddl_only_replication AND include_only_repset_tables)); 

-- Need to adjust to after trigger and change function def 
DROP TRIGGER unique_tags ON pgl_ddl_deploy.set_configs;
DROP FUNCTION pgl_ddl_deploy.unique_tags();

-- We need to add the column include_everything to it in a nice order
DROP VIEW pgl_ddl_deploy.event_trigger_schema;

-- Support canceling or terminating blocking processes on subscriber
CREATE TYPE pgl_ddl_deploy.signals AS ENUM ('cancel','terminate');
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN signal_blocking_subscriber_sessions pgl_ddl_deploy.signals;
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN subscriber_lock_timeout INT;

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT valid_signal_blocker_config
  CHECK
  (NOT (lock_safe_deployment AND (signal_blocking_subscriber_sessions IS NOT NULL OR subscriber_lock_timeout IS NOT NULL))
    AND NOT (subscriber_lock_timeout IS NOT NULL AND signal_blocking_subscriber_sessions IS NULL));

CREATE TABLE pgl_ddl_deploy.killed_blockers
(
  id           SERIAL PRIMARY KEY,
  signal       TEXT,
  successful   BOOLEAN,
  pid          INT,
  executed_at  TIMESTAMPTZ,
  usename      NAME,
  client_addr  INET,
  xact_start   TIMESTAMPTZ,
  state_change TIMESTAMPTZ,
  state        TEXT,
  query        TEXT,
  reported     BOOLEAN DEFAULT FALSE
);
