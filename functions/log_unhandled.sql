CREATE OR REPLACE FUNCTION pgl_ddl_deploy.log_unhandled(p_set_config_id integer, p_set_name text, p_pid integer, p_ddl_sql_raw text, p_command_tag text, p_reason text, p_txid bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    c_unhandled_msg TEXT = 'Unhandled deployment logged in pgl_ddl_deploy.unhandled';
BEGIN
INSERT INTO pgl_ddl_deploy.unhandled
  (set_config_id,
   set_name,
   pid,
   executed_at,
   ddl_sql_raw,
   command_tag,
   reason,
   txid)
VALUES
  (p_set_config_id,
   p_set_name,
   p_pid,
   current_timestamp,
   p_ddl_sql_raw,
   p_command_tag,
   p_reason,
   p_txid);
RAISE WARNING '%', c_unhandled_msg;
END;
$function$
;