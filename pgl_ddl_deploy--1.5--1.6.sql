/* pgl_ddl_deploy--1.5--1.6.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

CREATE OR REPLACE FUNCTION pgl_ddl_deploy.raise_message
(p_log_level TEXT,
p_message TEXT)
RETURNS BOOLEAN 
AS $BODY$
BEGIN

EXECUTE format($$
DO $block$
BEGIN
RAISE %s $pgl_ddl_deploy_msg$%s$pgl_ddl_deploy_msg$;
END$block$;
$$, p_log_level, REPLACE(p_message,'%','%%'));
RETURN TRUE;

END;
$BODY$
LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.standard_create_tags()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT '{
  "ALTER TABLE"
  ,"CREATE SEQUENCE"
  ,"ALTER SEQUENCE"
  ,"CREATE SCHEMA"
  ,"CREATE TABLE"
  ,"CREATE FUNCTION"
  ,"ALTER FUNCTION"
  ,"CREATE TYPE"
  ,"ALTER TYPE"
  ,"CREATE VIEW"
  ,"ALTER VIEW"
  ,COMMENT
  ,"CREATE RULE"
  ,"CREATE TRIGGER"
  ,"ALTER TRIGGER"}'::TEXT[];
$function$
;

