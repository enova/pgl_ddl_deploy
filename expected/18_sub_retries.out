SET client_min_messages = warning;

--Some day, we should regress with multiple databases.  There are examples of this in pglogical code base
--For now, we will mock the subscriber behavior, which is less than ideal, because it misses testing execution
--on subscriber

DROP OWNED BY test_pgl_ddl_deploy;
DROP ROLE test_pgl_ddl_deploy;
DROP ROLE test_pgl_ddl_deploy_nopriv;
DROP EXTENSION pgl_ddl_deploy CASCADE;

CREATE EXTENSION pgl_ddl_deploy;

SET SESSION_REPLICATION_ROLE TO REPLICA; --To ensure testing subscriber behavior
SET ROLE test_pgl_ddl_deploy;

--Mock subscriber_log insert which should take place on subscriber error when option enabled
INSERT INTO pgl_ddl_deploy.subscriber_logs
  (set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message)
VALUES
  ('foo',
   100,
   'awesome',
   1,
   current_role,
   pg_backend_pid(),
   current_timestamp,
   'CREATE VIEW joy AS SELECT * FROM joyous',
   'SET ROLE test_pgl_ddl_deploy; CREATE VIEW joy AS SELECT * FROM joyous;',
   FALSE,
   'relation "joyous" does not exist');

RESET ROLE;

SELECT pgl_ddl_deploy.retry_all_subscriber_logs();

SELECT pgl_ddl_deploy.retry_subscriber_log(rq.id)
FROM pgl_ddl_deploy.subscriber_logs rq
INNER JOIN pgl_ddl_deploy.subscriber_logs rqo ON rqo.id = rq.origin_subscriber_log_id
WHERE NOT rq.succeeded AND rq.next_subscriber_log_id IS NULL AND NOT rq.retrying
ORDER BY rqo.executed_at ASC, rqo.origin_subscriber_log_id ASC;

SELECT set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message
FROM pgl_ddl_deploy.subscriber_logs ORDER BY id;

CREATE TABLE joyous (id int);

SELECT pgl_ddl_deploy.retry_all_subscriber_logs();
SELECT pgl_ddl_deploy.retry_all_subscriber_logs();

SELECT set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message
FROM pgl_ddl_deploy.subscriber_logs ORDER BY id;

--Now let's do 2
INSERT INTO pgl_ddl_deploy.subscriber_logs
  (set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message)
VALUES
  ('foo',
   101,
   'awesome',
   1,
   current_role,
   pg_backend_pid(),
   current_timestamp,
   'CREATE VIEW happy AS SELECT * FROM happier;',
   'SET ROLE test_pgl_ddl_deploy; CREATE VIEW happy AS SELECT * FROM happier;',
   FALSE,
   'relation "happier" does not exist');

INSERT INTO pgl_ddl_deploy.subscriber_logs
  (set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message)
VALUES
  ('foo',
   102,
   'awesome',
   1,
   current_role,
   pg_backend_pid(),
   current_timestamp,
   'CREATE VIEW glee AS SELECT * FROM gleeful;',
   'SET ROLE test_pgl_ddl_deploy; CREATE VIEW glee AS SELECT * FROM gleeful;',
   FALSE,
   'relation "gleeful" does not exist');

--Both fail
SELECT pgl_ddl_deploy.retry_all_subscriber_logs();

SELECT set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message
FROM pgl_ddl_deploy.subscriber_logs ORDER BY id;

--One succeeds, one fails
CREATE TABLE happier (id int);
SELECT pgl_ddl_deploy.retry_all_subscriber_logs();

--One fails
SELECT pgl_ddl_deploy.retry_all_subscriber_logs();

SELECT set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message
FROM pgl_ddl_deploy.subscriber_logs ORDER BY id;

--Succeed with new id
CREATE TABLE gleeful (id int);
SELECT pgl_ddl_deploy.retry_subscriber_log(rq.id)
FROM pgl_ddl_deploy.subscriber_logs rq
INNER JOIN pgl_ddl_deploy.subscriber_logs rqo ON rqo.id = rq.origin_subscriber_log_id
WHERE NOT rq.succeeded AND rq.next_subscriber_log_id IS NULL AND NOT rq.retrying
ORDER BY rqo.executed_at ASC, rqo.origin_subscriber_log_id ASC;

--Nothing
SELECT pgl_ddl_deploy.retry_subscriber_log(rq.id)
FROM pgl_ddl_deploy.subscriber_logs rq
INNER JOIN pgl_ddl_deploy.subscriber_logs rqo ON rqo.id = rq.origin_subscriber_log_id
WHERE NOT rq.succeeded AND rq.next_subscriber_log_id IS NULL AND NOT rq.retrying
ORDER BY rqo.executed_at ASC, rqo.origin_subscriber_log_id ASC;

SELECT pgl_ddl_deploy.retry_all_subscriber_logs();

SELECT set_name,
   provider_pid,
   provider_node_name,
   provider_set_config_id,
   executed_as_role,
   subscriber_pid,
   executed_at,
   ddl_sql,
   full_ddl_sql,
   succeeded,
   error_message
FROM pgl_ddl_deploy.subscriber_logs ORDER BY id;

