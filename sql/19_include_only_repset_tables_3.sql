SET client_min_messages = warning;
SET ROLE test_pgl_ddl_deploy;

ALTER TABLE special.foo ADD COLUMN happy TEXT;
ALTER TABLE special.bar ADD COLUMN happier TEXT;

SELECT c.create_tags, c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
WHERE c.set_name LIKE 'my_special_tables%'
ORDER BY e.id DESC LIMIT 10;

--Test renaming which was missing in 1.2
ALTER TABLE special.foo RENAME COLUMN happy to happyz;
ALTER TABLE special.foo ADD CONSTRAINT bla CHECK (true);
ALTER TABLE special.foo RENAME CONSTRAINT bla to blaz;
ALTER TABLE special.foo RENAME COLUMN id TO id_2;
ALTER TABLE special.bar RENAME COLUMN happier TO happierz;
ALTER TABLE special.bar RENAME COLUMN id TO id_3;
ALTER TABLE special.foo RENAME TO fooz;
ALTER TABLE special.bar RENAME TO barz;

SELECT c.set_name, ddl_sql_raw, ddl_sql_sent
FROM pgl_ddl_deploy.events e
INNER JOIN pgl_ddl_deploy.set_configs c ON c.id = e.set_config_id
WHERE c.set_name LIKE 'my_special_tables%' ORDER BY e.id DESC LIMIT 20;

--None of these appear in special tables replication events
DROP TABLE special.fooz CASCADE;
DROP TABLE special.barz CASCADE;
DROP SCHEMA special;
