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
