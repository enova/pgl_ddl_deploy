-- Suppress pid-specific warning messages
SET client_min_messages TO error;

INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_schema_regex, lock_safe_deployment, allow_multi_statements)
VALUES ('test1','.*',true, true);

-- It's generally good to use queue_subscriber_failures with include_everything, so a bogus grant won't break replication on subscriber
INSERT INTO pgl_ddl_deploy.set_configs (set_name, include_everything, queue_subscriber_failures, create_tags)
VALUES ('test1',true, true, '{GRANT,REVOKE}');

SELECT pgl_ddl_deploy.deploy(id) FROM pgl_ddl_deploy.set_configs WHERE set_name = 'test1';
DISCARD TEMP;

SET search_path TO public;
SET ROLE test_pgl_ddl_deploy;
CREATE TABLE foo(id serial primary key, bla int);
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

GRANT SELECT ON foo TO PUBLIC; 
SELECT c.set_name, ddl_sql_raw, ddl_sql_sent, c.include_everything
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY e.id DESC LIMIT 10;

INSERT INTO foo (bla) VALUES (1),(2),(3);

REVOKE INSERT ON foo FROM PUBLIC;
DROP TABLE foo CASCADE;
SELECT c.set_name, ddl_sql_raw, ddl_sql_sent, c.include_everything
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY e.id DESC LIMIT 10;

SELECT * FROM pgl_ddl_deploy.unhandled;
SELECT * FROM pgl_ddl_deploy.exceptions;

/*****
Test cancel and terminate blocker functionality
*****/
SET ROLE postgres;
UPDATE pgl_ddl_deploy.set_configs SET lock_safe_deployment = FALSE, signal_blocking_subscriber_sessions = 'cancel';
SELECT pgl_ddl_deploy.deploy(id) FROM pgl_ddl_deploy.set_configs WHERE set_name = 'test1';

SET ROLE test_pgl_ddl_deploy;
CREATE TABLE foo(id serial primary key, bla int);
SELECT set_name, ddl_sql_raw, ddl_sql_sent FROM pgl_ddl_deploy.events ORDER BY id DESC LIMIT 10;

GRANT SELECT ON foo TO PUBLIC; 
SELECT c.set_name, ddl_sql_raw, ddl_sql_sent, c.include_everything
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY e.id DESC LIMIT 10;

INSERT INTO foo (bla) VALUES (1),(2),(3);

REVOKE INSERT ON foo FROM PUBLIC;
DROP TABLE foo CASCADE;
SELECT c.set_name, ddl_sql_raw, ddl_sql_sent, c.include_everything
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
ORDER BY e.id DESC LIMIT 10;

SELECT * FROM pgl_ddl_deploy.unhandled;
SELECT * FROM pgl_ddl_deploy.exceptions;

CREATE TABLE public.foo(id serial primary key, bla int);
CREATE TABLE public.foo2 () INHERITS (public.foo);
CREATE TABLE public.foo3 (id serial primary key, foo_id int references public.foo (id));
CREATE TABLE public.bar(id serial primary key, bla int);
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; SELECT * FROM public.foo; SELECT pg_sleep(30);" > /dev/null 2>&1 &
SELECT pg_sleep(1);
SELECT signal, successful, state, query, reported, pg_sleep(1) 
FROM pgl_ddl_deploy.kill_blockers('cancel','public','foo');
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; SELECT * FROM public.foo; SELECT pg_sleep(30);" > /dev/null 2>&1 &
SELECT pg_sleep(1);
SELECT signal, successful, state, query, reported, pg_sleep(1) 
FROM pgl_ddl_deploy.kill_blockers('terminate','public','foo');

\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; SELECT * FROM public.foo; SELECT pg_sleep(30);" > /dev/null 2>&1 &
-- This process should not be killed
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; INSERT INTO public.bar (bla) VALUES (1); SELECT pg_sleep(2); COMMIT;" > /dev/null 2>&1 &
SELECT pg_sleep(1);

SELECT pgl_ddl_deploy.subscriber_command
    (
      p_provider_name := 'test',
      p_set_name := ARRAY['test1'],
      p_nspname := 'public',
      p_relname := 'foo',
      p_ddl_sql_sent := $pgl_ddl_deploy_sql$ALTER TABLE public.foo ADD COLUMN bar text;$pgl_ddl_deploy_sql$,
      p_full_ddl := $pgl_ddl_deploy_sql$
                --Be sure to use provider's search_path for SQL environment consistency
                    SET SEARCH_PATH TO public;

                    ALTER TABLE public.foo ADD COLUMN bar text;
                    ;
                $pgl_ddl_deploy_sql$,
      p_pid := pg_backend_pid(),
      p_set_config_id := 1,
      p_queue_subscriber_failures := false,
      p_signal_blocking_subscriber_sessions := 'cancel',
    -- Lower lock_timeout to make this test run faster
      p_lock_timeout := 300,
    -- This parameter is only marked TRUE for this function to be able to easily run on a provider for regression testing
      p_run_anywhere := TRUE
);
TABLE public.foo;

-- Now two processes to be killed
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; SELECT * FROM public.foo; SELECT pg_sleep(30);" > /dev/null 2>&1 &
SELECT pg_sleep(1);
-- This process will wait for the one above - but we want it to fail regardless of which gets killed first
-- Avoid it firing our event triggers by using session_replication_role = replica
\! PGOPTIONS='--client-min-messages=warning --session-replication-role=replica' psql -d contrib_regression  -c "BEGIN; ALTER TABLE public.foo DROP COLUMN bar; SELECT pg_sleep(30);" > /dev/null 2>&1 &
SELECT pg_sleep(2);

SELECT pgl_ddl_deploy.subscriber_command
    (
      p_provider_name := 'test',
      p_set_name := ARRAY['test1'],
      p_nspname := 'public',
      p_relname := 'foo',
      p_ddl_sql_sent := $pgl_ddl_deploy_sql$ALTER TABLE public.foo ADD COLUMN super text;$pgl_ddl_deploy_sql$,
      p_full_ddl := $pgl_ddl_deploy_sql$
                --Be sure to use provider's search_path for SQL environment consistency
                    SET SEARCH_PATH TO public;

                    ALTER TABLE public.foo ADD COLUMN super text;
                    ;
                $pgl_ddl_deploy_sql$,
      p_pid := pg_backend_pid(),
      p_set_config_id := 1,
      p_queue_subscriber_failures := false,
      p_signal_blocking_subscriber_sessions := 'terminate',
    -- Lower lock_timeout to make this test run faster
      p_lock_timeout := 300,
    -- This parameter is only marked TRUE for this function to be able to easily run on a provider for regression testing
      p_run_anywhere := TRUE
);
TABLE public.foo;

/****
Try cancel_then_terminate, which should first try to cancel
****/
-- This process should be killed
\! echo "BEGIN; SELECT * FROM public.foo;\n\! sleep 15" | psql contrib_regression > /dev/null 2>&1 &

-- This process should not be killed
\! psql contrib_regression -c "BEGIN; INSERT INTO public.bar (bla) VALUES (1); SELECT pg_sleep(5); COMMIT;" > /dev/null 2>&1 &

SELECT pg_sleep(1);

SELECT pgl_ddl_deploy.subscriber_command
    (
      p_provider_name := 'test',
      p_set_name := ARRAY['test1'],
      p_nspname := 'public',
      p_relname := 'foo',
      p_ddl_sql_sent := $pgl_ddl_deploy_sql$ALTER TABLE public.foo ALTER COLUMN bar SET NOT NULL;$pgl_ddl_deploy_sql$,
      p_full_ddl := $pgl_ddl_deploy_sql$
                --Be sure to use provider's search_path for SQL environment consistency
                    SET SEARCH_PATH TO public;

                    ALTER TABLE public.foo ALTER COLUMN bar SET NOT NULL;
                    ;
                $pgl_ddl_deploy_sql$,
      p_pid := pg_backend_pid(),
      p_set_config_id := 1,
      p_queue_subscriber_failures := false,
      p_signal_blocking_subscriber_sessions := 'cancel_then_terminate',
    -- Lower lock_timeout to make this test run faster
      p_lock_timeout := 300,
    -- This parameter is only marked TRUE for this function to be able to easily run on a provider for regression testing
      p_run_anywhere := TRUE
);
TABLE public.foo;

/*** TEST INHERITANCE AND PARTITIONING ***/
-- Same workflow as above, but instead select from child, alter parent
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; SELECT * FROM public.foo2; SELECT pg_sleep(30);" > /dev/null 2>&1 &
SELECT pg_sleep(1);
SELECT signal, successful, state, query, reported, pg_sleep(1)
FROM pgl_ddl_deploy.kill_blockers('terminate','public','foo');
/*** With <=1.5, it showed this.  But it should kill the process.
 signal | successful | state | query | reported | pg_sleep
--------+------------+-------+-------+----------+----------
(0 rows)
***/

/*** TEST FKEY RELATED TABLE BLOCKER KILLER ***/
-- Same workflow as above, but instead select from a table which has an fkey reference to foo.id 
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; SELECT * FROM public.foo3; SELECT pg_sleep(30);" > /dev/null 2>&1 &
SELECT pg_sleep(1);
SELECT signal, successful, state, query, reported, pg_sleep(1)
FROM pgl_ddl_deploy.kill_blockers('terminate','public','foo');
/*** With <=1.5, it showed this.  But it should kill the process.
 signal | successful | state | query | reported | pg_sleep
--------+------------+-------+-------+----------+----------
(0 rows)
***/

/*** TEST REFERENCED BY TABLE BLOCKER KILLER ***/
-- Same workflow as above, but instead select from a table which has a pkey (foo) which is referenced by another table being altered (foo3) 
\! PGOPTIONS='--client-min-messages=warning' psql -d contrib_regression  -c "BEGIN; SELECT * FROM public.foo; SELECT pg_sleep(30);" > /dev/null 2>&1 &
SELECT pg_sleep(1);
SELECT signal, successful, state, query, reported, pg_sleep(1)
FROM pgl_ddl_deploy.kill_blockers('terminate','public','foo3');
/*** With <=1.5, it showed this.  But it should kill the process.
 signal | successful | state | query | reported | pg_sleep
--------+------------+-------+-------+----------+----------
(0 rows)
***/

SET lock_timeout TO 1000;
DROP TABLE public.foo CASCADE;
-- With <=1.5, lock is still in place leading to ERROR:  canceling statement due to lock timeout
DROP TABLE public.foo3 CASCADE;
-- With <=1.5, lock is still in place leading to ERROR:  canceling statement due to lock timeout
TABLE bar;
DROP TABLE public.bar CASCADE;

SELECT signal, successful, state, query, reported
FROM pgl_ddl_deploy.killed_blockers
ORDER BY signal, query;

SELECT pg_sleep(1);

-- Should be zero - everything was killed
SELECT COUNT(1)
FROM pg_stat_activity
WHERE usename = session_user
  AND NOT pid = pg_backend_pid()
  AND query LIKE '%public.foo%';
