-- Configure this to only replicate functions or views
-- This test is to ensure the config does NOT auto-add tables to replication (bug with <=1.5)
UPDATE pgl_ddl_deploy.set_configs
SET create_tags = '{"CREATE FUNCTION","ALTER FUNCTION","CREATE VIEW","ALTER VIEW"}'
, drop_tags = '{"DROP FUNCTION","DROP VIEW"}'
WHERE set_name = 'testspecial';

SELECT pgl_ddl_deploy.deploy('testspecial');

CREATE TEMP VIEW tables_in_replication AS 
SELECT COUNT(1)
FROM pgl_ddl_deploy.rep_set_table_wrapper() t
INNER JOIN pglogical.replication_set rs USING (set_id)
WHERE rs.set_name = 'testspecial';

TABLE tables_in_replication;

CREATE TABLE special.do_not_replicate_me(id int primary key);

TABLE tables_in_replication;

-- In <=1.5, this would have hit the code path to add new tables to replication, even though
-- the set is configured not to replicate CREATE TABLE events
CREATE FUNCTION special.do_replicate_me()
RETURNS INT
AS 'SELECT 1'
LANGUAGE SQL;

-- This SHOULD show the same as above, but showed 1 more table in <=1.5
TABLE tables_in_replication;

-- Test to ensure we are only setting these defaults (trigger set_tag_defaults) on INSERT
UPDATE pgl_ddl_deploy.set_configs
SET drop_tags = NULL
WHERE set_name = 'testspecial'
RETURNING drop_tags;
/*
In <= 1.5, returned this:
                                      drop_tags
--------------------------------------------------------------------------------------
 {"DROP SCHEMA","DROP TABLE","DROP FUNCTION","DROP TYPE","DROP VIEW","DROP SEQUENCE"}
(1 row)
*/
