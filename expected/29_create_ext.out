-- Allow running regression suite with upgrade paths
\set v `echo ${FROMVERSION:-2.0}`
SET client_min_messages = warning;
DO $$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
RAISE LOG '%', 'USING NATIVE';

ELSE
CREATE EXTENSION pglogical;
END IF;

END$$;
CREATE EXTENSION pgl_ddl_deploy VERSION :'v';
CREATE FUNCTION set_driver() RETURNS VOID AS $BODY$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
    ALTER TABLE pgl_ddl_deploy.set_configs ALTER COLUMN driver SET DEFAULT 'native'::pgl_ddl_deploy.driver;
END IF;

END;
$BODY$
LANGUAGE plpgsql;
SELECT set_driver();
