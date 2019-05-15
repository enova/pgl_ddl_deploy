SET client_min_messages TO WARNING;
ALTER EXTENSION pgl_ddl_deploy UPDATE;

-- Simple example
SELECT pgl_ddl_deploy.raise_message('WARNING', 'foo');

-- Test case that needs % escapes
SELECT pgl_ddl_deploy.raise_message('WARNING', $$SELECT foo FROM bar WHERE baz LIKE 'foo%'$$);
/*** Failing message on 1.5 read:
ERROR:  too few parameters specified for RAISE
CONTEXT:  compilation of PL/pgSQL function "inline_code_block" near line 3
SQL statement "
DO $block$
BEGIN
RAISE WARNING $pgl_ddl_deploy_msg$SELECT foo FROM bar WHERE baz LIKE 'foo%'$pgl_ddl_deploy_msg$;
END$block$;
"
PL/pgSQL function pgl_ddl_deploy.raise_message(text,text) line 4 at EXECUTE
***/
