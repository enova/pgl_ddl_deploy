--****NOTE*** this file drops the whole extension and all previous test setup.
--If adding new tests, it is best to keep this file as the last test before cleanup.
SET client_min_messages = warning;

ALTER EXTENSION pgl_ddl_deploy UPDATE TO '1.4';
