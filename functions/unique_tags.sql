CREATE OR REPLACE FUNCTION pgl_ddl_deploy.unique_tags()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT NEW.ddl_only_replication AND EXISTS (
    SELECT 1
    FROM pgl_ddl_deploy.set_configs
    WHERE id <> NEW.id
      AND set_name = NEW.set_name
      AND NOT NEW.ddl_only_replication
      AND (create_tags && NEW.create_tags
      OR drop_tags && NEW.drop_tags)) THEN
    RAISE EXCEPTION $$Another set_config already exists for '%' with overlapping create_tags or drop_tags.
    Command tags must only appear once per set_name even if using multiple set_configs, unless you
    are using the ddl_only_replication setting.
    $$, NEW.set_name;
  END IF;
  RETURN NEW;
END;
$function$
;
