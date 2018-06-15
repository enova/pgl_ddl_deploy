CREATE OR REPLACE FUNCTION pgl_ddl_deploy.set_tag_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
IF NEW.create_tags IS NULL THEN
    NEW.create_tags = CASE WHEN NEW.include_only_repset_tables THEN '{"ALTER TABLE"}' ELSE pgl_ddl_deploy.standard_create_tags() END;
END IF;
IF NEW.drop_tags IS NULL THEN
    NEW.drop_tags = CASE WHEN NEW.include_only_repset_tables THEN NULL ELSE pgl_ddl_deploy.standard_drop_tags() END;
END IF;
RETURN NEW;
END;
$function$
;