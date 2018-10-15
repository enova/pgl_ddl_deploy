SET client_min_messages = warning;

CREATE FUNCTION noop() RETURNS TRIGGER AS $BODY$
BEGIN
RETURN NULL;
END;
$BODY$
LANGUAGE plpgsql;

CREATE TRIGGER noop BEFORE DELETE ON special.fooz FOR EACH ROW EXECUTE PROCEDURE noop();
ALTER TABLE special.fooz DISABLE TRIGGER noop;

SELECT c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
WHERE c.set_name LIKE 'my_special_tables%' ORDER BY e.id DESC LIMIT 10;

-- Test new subcommand functionality
UPDATE pgl_ddl_deploy.set_configs
SET exclude_alter_table_subcommands = pgl_ddl_deploy.common_exclude_alter_table_subcommands()
WHERE include_only_repset_tables;

SELECT pgl_ddl_deploy.deploy(id)
FROM pgl_ddl_deploy.set_configs
WHERE include_only_repset_tables;

SET client_min_messages = log;
-- This should be ignored
ALTER TABLE special.fooz ENABLE TRIGGER noop;

-- This contains a tag we want to ignore but we can't separate out the parts - see the warning message
ALTER TABLE special.barz ADD COLUMN foo_id INT REFERENCES special.fooz (id_2);
ALTER TABLE special.fooz ADD COLUMN bar_id INT;

-- This one should be ignored as well
ALTER TABLE special.fooz ADD CONSTRAINT coolness FOREIGN KEY (bar_id) REFERENCES special.barz (id_3);

SELECT c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
WHERE c.set_name LIKE 'my_special_tables%' ORDER BY e.id DESC LIMIT 10;

SET client_min_messages = warning;
DROP TABLE special.fooz CASCADE;
DROP TABLE special.barz CASCADE;
DROP SCHEMA special;
